#!/usr/bin/env python3
# PreToolUse(Bash): block GitHub API polling patterns that burn the shared 5000/hr quota,
# and point the agent at gh-wait (ETag conditional requests; 304s are free).
import json
import os
import re
import socket
import sys
import time

# One JSON line per deny, so false positives and real offenders can be reviewed later.
# GH_QUOTA_HOOK_LOG overrides it (tests/hooktest.sh sets /dev/null so test cases don't pollute it).
LOG = os.environ.get('GH_QUOTA_HOOK_LOG') or os.path.expanduser('~/.local/state/gh-quota/hook.log')
LOG_MAX_BYTES = 1_000_000

# Command position: start of line or after ; & | ( ! quote `$(` do/then/while/until/if,
# then optional VAR=x and wrappers. Quotes count so that `ssh host 'gh run watch'` and
# `bash -c "..."` are caught (the remote side has no hook); the cost is that prose in a
# quoted string starting with `gh run watch` is blocked too.
SEP = r'(?:^|[;&|(!\n"\']|\$\(|\b(?:do|then|while|until|if)\b)\s*'
# One shell word, quotes included (`"StrictHostKeyChecking no"`, `X="a b"`). Each character
# has exactly one way to match, so a word ends only at unquoted whitespace.
WORD = r'''(?:[^\s'"]|'[^']*'|"(?:\\.|[^"\\])*")+'''
# Every wrapper parses one way only: an option's argument can never itself look like an
# option, so text that repeats `ssh` or `env -u` many times cannot backtrack exponentially.
SSH = r'ssh(?:\s+-' + WORD + r'(?:\s+(?![-\s])' + WORD + r')?)*\s+(?![-\s])' + WORD  # options, then the host
WRAP = (r'(?:\w+=\S*\s+'
        r'|timeout\s+(?:-\S+\s+(?:\d\S*\s+)?)*\S+\s+'
        r'|nice\s+(?:-n\s*-?\d+\s+|-\d+\s+)?|env\s+(?:-u\s*[^\s-]\S*\s+|-[^\su]\S*\s+)*'
        r'|stdbuf\s+(?:-[ioe]\s*[^\s-]\S*\s+|--\S+\s+)*'
        r'|xargs\s+(?:-\S+\s+(?:\d+\s+)?)*'
        r'|' + SSH + r'\s+'
        r'|(?:nohup|sudo|time|command|exec)\s+)*')
POS = SEP + WRAP
# gh, also by path, with -R/--repo wherever gh accepts it (before or after the command group).
PATH_PREFIX = r'(?:[^\s;&|()<>\'"`]*/)?'  # a command called by path: /opt/homebrew/bin/gh
GH = PATH_PREFIX + r'gh'
REPO = r'(?:\s+(?:-R\s*|--repo(?:\s+|=))[^\s;&|]+)*'
WATCH = re.compile(POS + GH + REPO + r'\s+run' + REPO + r'\s+watch\b')
CHECKS = re.compile(POS + GH + REPO + r'\s+pr' + REPO + r'\s+checks\b[^;&|\n]*--watch')
# watch(1) re-runs its command forever, every 2 s by default.
WATCH_CMD = re.compile(POS + r'watch\b[^;&|\n]*\bgh\s')
# Loop keywords and `done` at command position; matched on a copy with quoted text blanked,
# so `echo "done"` or `x-done` never closes a loop.
LOOP_KW = re.compile(r'(?:^|[;&|(\n]|\bdo\b|\bthen\b|\belse\b)\s*(while|until|for|done)\b')
# `while read …` consumes finite input (a file, a pipe), so like `for` it is a batch, not polling.
READ_COND = re.compile(r'\s+(?:\w+=(?:' + WORD + r')?\s+)*read\b')
QUOTED = re.compile(r"'[^']*'|\"(?:\\.|[^\"\\])*\"")
# In a loop any gh subcommand counts, except those that never call the API
# (and auth: `gh auth token` / `gh auth status` are cheap and sit next to real calls).
GH_CALL = re.compile(POS + r'(?P<gh>' + GH + r')' + REPO
                     + r'\s+(?!(?:auth|config|alias|completion|help|version)\b)[a-z]')
# Loop variables: `for r in …` and the names `while read [-r] r …` assigns.
FOR_VAR = re.compile(r'for\s+([A-Za-z_]\w*)\s+in\b')
READ_ARGS = re.compile(r'\bread\b([^;\n]*?)(?:;|\n|\bdo\b)')
READ_VAR = re.compile(r'(?<![-\w])([A-Za-z_]\w*)\b')
SLEEP = re.compile(r'\bsleep\s+([^\s;&|)]+)')
LITERAL = re.compile(r'(\d+(?:\.\d+)?)([smhd]?)')
UNIT = {'': 1, 's': 1, 'm': 60, 'h': 3600, 'd': 86400}
# Anonymous REST calls share the exit IP's 60/hr; `gh api` uses the account's 5000/hr.
# /rate_limit itself is free, so checking the anonymous quota is allowed. The match runs to
# the end of that curl's own command, where its auth header (if any) has to be.
# A backslash-newline continues the same command, so `\\<newline>  -H "Authorization: …"`
# still belongs to that curl.
ARGS = r'(?:[^;&|\n\\]|\\[\s\S])*'
ANON_CURL = re.compile(POS + r'(?:curl|wget)\b' + ARGS + r'(?i:api\.github\.com)(?!/rate_limit\b)' + ARGS)
AUTH = re.compile(r'(?i)authorization:|\$\(gh auth token\)|\$\{?(?:GITHUB_TOKEN|GH_TOKEN)\b')
# Wrappers whose quoted argument is itself a command line (sh -c, ssh host, eval): their
# loops are hidden from loops(), so reason() runs again on the unquoted argument. Group w
# starts at the wrapper itself; it only counts when that spot is shell code (see code_mask).
PAYLOAD = re.compile(SEP + r'(?P<w>' + WRAP + r'(?:' + PATH_PREFIX + r'(?:ba|z|da|k)?sh(?:\s+-[\w-]+)*\s+|'
                     + SSH + r'\s+|eval\s+))(?P<q>\'[^\']*\'|"(?:\\.|[^"\\])*")')
HEREDOC = re.compile(r'<<(-)?\s*([\'"]?)(\w+)\2')
CODE, QUOTE, HEREDOC_BODY = 0, 1, 2
MAX_DEPTH = 3

HINT = ('等 CI 請改用 `gh-wait run <run-id> -R owner/repo` 或 `gh-wait pr <number> -R owner/repo`'
        '（ETag 條件請求，狀態沒變時 304 不扣額度；放背景跑，結束會通知）。'
        '如果是為了等 checks 過了就合併，考慮 `gh pr merge --auto`。')


def code_mask(cmd):
    """Classify every character in one linear pass: CODE, QUOTE (inside '…' or "…", except
    a $(…) inside "…", which is code again) or HEREDOC_BODY. An unclosed quote stays code."""
    n = len(cmd)
    mask = bytearray(n)
    stack = []  # '"' while inside double quotes, '(' for each $( or ( opened inside them
    heredocs = []  # (delimiter, strip_tabs) whose bodies start after the current line
    i = 0
    while i < n:
        c = cmd[i]
        if stack and stack[-1] == '"':
            if c == '\\':
                mask[i:i + 2] = bytes([QUOTE]) * len(mask[i:i + 2])
                i += 2
                continue
            mask[i] = QUOTE
            if c == '"':
                stack.pop()
            elif cmd.startswith('$(', i):
                mask[i + 1] = QUOTE
                stack.append('(')
                i += 1
            i += 1
        elif c == '\\':
            i += 2
        elif c == "'":
            j = cmd.find("'", i + 1)
            if j < 0:
                i += 1
            else:
                mask[i:j + 1] = bytes([QUOTE]) * (j + 1 - i)
                i = j + 1
        elif c == '"':
            if cmd.find('"', i + 1) >= 0:
                mask[i] = QUOTE
                stack.append('"')
            i += 1
        elif c == '(' and stack:
            stack.append('(')
            i += 1
        elif c == ')' and stack:
            stack.pop()
            i += 1
        elif c == '<' and cmd.startswith('<<<', i):
            i += 3  # here-string: its operand is a word, never a heredoc delimiter
        elif c == '<' and cmd.startswith('<<', i):
            m = HEREDOC.match(cmd, i)
            if m:
                heredocs.append((m.group(3), bool(m.group(1))))
                i = m.end()
            else:
                i += 2
        elif c == '\n' and heredocs:
            i += 1
            for delim, strip in heredocs:
                start = i
                while i < n:
                    end = cmd.find('\n', i)
                    end = n if end < 0 else end
                    line = cmd[i:end]
                    if (line.lstrip('\t') if strip else line) == delim:
                        mask[start:i] = bytes([HEREDOC_BODY]) * (i - start)
                        i = end + 1
                        break
                    i = end + 1
                else:
                    mask[start:n] = bytes([HEREDOC_BODY]) * (n - start)
            heredocs = []
        else:
            i += 1
    return mask


def payloads(cmd, mask, start=0, end=None):
    """Yield the unquoted argument of each sh -c / ssh host / eval whose wrapper sits in shell
    code, not inside another quoted argument (a commit message) or a heredoc body."""
    end = len(cmd) if end is None else end
    pos = start
    while True:
        m = PAYLOAD.search(cmd, pos, end)
        if not m:
            return
        if mask[m.start('w')] != CODE:
            pos = m.start('w') + 1
            continue
        pos = m.end()
        q = m.group('q')
        inner = q[1:-1]
        if q[0] == '"':
            inner = re.sub(r'\\([\\"$`])', r'\1', inner)
        yield inner


def gh_called(cmd, mask, start, end, depth):
    """True when cmd[start:end] runs gh: at a command position outside quoted text (echo "gh is
    up" is not a call; "$(gh …)" is), or inside a payload such as ssh host "gh api x"."""
    if any(mask[m.start('gh')] != QUOTE for m in GH_CALL.finditer(cmd, start, end)):
        return True
    if depth < MAX_DEPTH:
        for inner in payloads(cmd, mask, start, end):
            if gh_called(inner, code_mask(inner), 0, len(inner), depth + 1):
                return True
    return False


def loops(cmd):
    """Yield (keyword, start, end) for each loop, its text running to its own matching `done`
    (or to the end when unterminated), so nested loops and gh after a loop judge right.
    A `while read …` loop is reported as keyword 'read'."""
    blank = QUOTED.sub(lambda m: m.group(0)[0] + ' ' * (len(m.group(0)) - 2) + m.group(0)[-1], cmd)
    open_loops = []
    for m in LOOP_KW.finditer(blank):
        kind = m.group(1)
        if kind == 'while' and READ_COND.match(cmd, m.end(1)):
            kind = 'read'
        if kind != 'done':
            open_loops.append((kind, m.start(1)))
        elif open_loops:
            kind, start = open_loops.pop()
            yield kind, start, m.end(1)
    for kind, start in open_loops:
        yield kind, start, len(cmd)


def batch(cmd, mask, kind, start, end):
    """True when a `for` / `while read` loop feeds its variable to every gh call in it
    (gh repo clone me/$r): one call per item is a batch however short its sleep. A gh call
    that ignores the loop variable (for i in $(seq 30); do gh run view 1 …) is polling."""
    if kind == 'for':
        m = FOR_VAR.match(cmd, start)
        names = [m.group(1)] if m else []
    else:
        m = READ_ARGS.search(cmd, start, end)
        names = READ_VAR.findall(m.group(1)) if m else []
    if not names:
        return False
    # gh inside a payload (bash -c 'gh api user') can't be tied to the item: not a batch.
    if any(gh_called(p, code_mask(p), 0, len(p), MAX_DEPTH) for p in payloads(cmd, mask, start, end)):
        return False
    uses = re.compile(r'\$\{?(?:' + '|'.join(names) + r')\b')
    calls = [m for m in GH_CALL.finditer(cmd, start, end) if mask[m.start('gh')] != QUOTE]
    for m in calls:
        # The request itself: its wrapper (ssh $h) through the first separator or redirection
        # outside quotes (--jq '.[] | .n' is one argument; > "out-$i" names a file and the
        # request is the same every time, so whatever follows it never counts).
        stop = next((k for k in range(m.start('gh'), end)
                     if cmd[k] in ';&|\n)<>' and mask[k] == CODE), end)
        if not uses.search(cmd, m.start(), stop):
            return False
    return bool(calls)


def reason(cmd, depth=0):
    if 'gh' not in cmd and 'github' not in cmd.lower():
        return None
    if WATCH.search(cmd):
        return '`gh run watch` 每輪打 2 個請求加每個執行中 job 1 個，會吃光共用的 5000/hr GitHub 額度。'
    if CHECKS.search(cmd):
        return '`gh pr checks --watch` 是固定間隔輪詢，會吃光共用的 5000/hr GitHub 額度。'
    if any(not AUTH.search(m.group(0)) for m in ANON_CURL.finditer(cmd)):
        return ('沒帶 token 的 curl／wget 打 api.github.com，吃的是出口 IP 共用的每小時 60 次匿名額度；'
                '改用 `gh api <path>`（走帳號的 5000 次）。')
    if WATCH_CMD.search(cmd):
        return '`watch … gh` 會每隔幾秒重跑 gh，會吃光共用的 5000/hr GitHub 額度。'
    mask = code_mask(cmd)
    for kind, start, end in loops(cmd):
        if not gh_called(cmd, mask, start, end, depth):
            continue
        if kind in ('for', 'read') and batch(cmd, mask, kind, start, end):
            continue
        body = cmd[start:end]
        args = [a.strip('\'"') for a in SLEEP.findall(body)]
        lits = [LITERAL.fullmatch(a) for a in args]
        sleeps = [float(m.group(1)) * UNIT[m.group(2)] for m in lits if m]
        if sleeps and min(sleeps) < 60:
            return f'用 sleep {min(sleeps):g} 秒的迴圈輪詢 gh，會吃光共用的 5000/hr GitHub 額度。'
        if not all(lits):
            return ('sleep 的間隔是變數或算式，hook 看不出有沒有至少 60 秒；'
                    '用迴圈輪詢 gh 會吃光共用的 5000/hr GitHub 額度。')
        # A `while read` that got here is not a batch (gh ignores what it reads), so without
        # sleep it spins like while/until; `for` over a fixed list ends by itself.
        if not args and kind in ('while', 'until', 'read'):
            return '沒有 sleep 的 while／until 迴圈呼叫 gh，會連續狂打共用的 5000/hr GitHub 額度。'
    if depth < MAX_DEPTH:
        for inner in payloads(cmd, mask):
            why = reason(inner, depth + 1)
            if why:
                return why
    return None


def log_deny(data, cmd, why):
    try:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        if os.path.exists(LOG) and os.path.getsize(LOG) > LOG_MAX_BYTES:
            os.replace(LOG, LOG + '.1')
        with open(LOG, 'a') as f:
            f.write(json.dumps({
                'ts': time.strftime('%Y-%m-%dT%H:%M:%S%z'),
                'host': socket.gethostname(),
                'session': data.get('session_id'),
                'cwd': data.get('cwd'),
                'reason': why.split('，')[0],
                'cmd': cmd[:500],
            }, ensure_ascii=False) + '\n')
    except OSError:
        pass


def main():
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return
    if not isinstance(data, dict):
        return
    tool_input = data.get('tool_input')
    cmd = tool_input.get('command') if isinstance(tool_input, dict) else None
    if not isinstance(cmd, str):
        return
    why = reason(cmd)
    if why:
        log_deny(data, cmd, why)
        json.dump({'hookSpecificOutput': {
            'hookEventName': 'PreToolUse',
            'permissionDecision': 'deny',
            'permissionDecisionReason': why + HINT,
        }}, sys.stdout, ensure_ascii=False)


if __name__ == '__main__':
    main()
