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
# Every wrapper parses one way only: an option's argument can never itself look like an
# option, so text that repeats `ssh` or `env -u` many times cannot backtrack exponentially.
SSH = r'ssh(?:\s+-\S+(?:\s+[^\s-]\S*)?)*\s+[^\s-]\S*'  # options, then the host
WRAP = (r'(?:\w+=\S*\s+'
        r'|timeout\s+(?:-\S+\s+(?:\d\S*\s+)?)*\S+\s+'
        r'|nice\s+(?:-n\s*-?\d+\s+|-\d+\s+)?|env\s+(?:-u\s*[^\s-]\S*\s+|-[^\su]\S*\s+)*'
        r'|stdbuf\s+(?:-[ioe]\s*[^\s-]\S*\s+|--\S+\s+)*'
        r'|xargs\s+(?:-\S+\s+(?:\d+\s+)?)*'
        r'|' + SSH + r'\s+'
        r'|(?:nohup|sudo|time|command|exec)\s+)*')
POS = SEP + WRAP
# gh, also by path, with -R/--repo wherever gh accepts it (before or after the command group).
GH = r'(?:[^\s;&|()<>\'"`]*/)?gh'
REPO = r'(?:\s+(?:-R\s*|--repo(?:\s+|=))[^\s;&|]+)*'
WATCH = re.compile(POS + GH + REPO + r'\s+run' + REPO + r'\s+watch\b')
CHECKS = re.compile(POS + GH + REPO + r'\s+pr' + REPO + r'\s+checks\b[^;&|\n]*--watch')
# watch(1) re-runs its command forever, every 2 s by default.
WATCH_CMD = re.compile(POS + r'watch\b[^;&|\n]*\bgh\s')
# Loop keywords and `done` at command position; matched on a copy with quoted text blanked,
# so `echo "done"` or `x-done` never closes a loop.
LOOP_KW = re.compile(r'(?:^|[;&|(\n]|\bdo\b|\bthen\b|\belse\b)\s*(while|until|for|done)\b')
QUOTED = re.compile(r"'[^']*'|\"(?:\\.|[^\"\\])*\"")
# In a loop any gh subcommand counts, except those that never call the API
# (and auth: `gh auth token` / `gh auth status` are cheap and sit next to real calls).
GH_CALL = re.compile(POS + GH + REPO + r'\s+(?!(?:auth|config|alias|completion|help|version)\b)[a-z]')
SLEEP = re.compile(r'\bsleep\s+([^\s;&|)]+)')
LITERAL = re.compile(r'(\d+(?:\.\d+)?)([smhd]?)')
UNIT = {'': 1, 's': 1, 'm': 60, 'h': 3600, 'd': 86400}
# Anonymous REST calls share the exit IP's 60/hr; `gh api` uses the account's 5000/hr.
# /rate_limit itself is free, so checking the anonymous quota is allowed. The match runs to
# the end of that curl's own command, where its auth header (if any) has to be.
ANON_CURL = re.compile(POS + r'(?:curl|wget)\b[^;&|\n]*(?i:api\.github\.com)(?!/rate_limit\b)[^;&|\n]*')
AUTH = re.compile(r'(?i)authorization:|\$\(gh auth token\)|\$\{?(?:GITHUB_TOKEN|GH_TOKEN)\b')
# Wrappers whose quoted argument is itself a command line (sh -c, ssh host, eval): their
# loops are hidden from loops(), so reason() runs again on the unquoted argument.
PAYLOAD = re.compile(POS + r'(?:(?:[^\s;&|()<>\'"`]*/)?(?:ba|z|da|k)?sh(?:\s+-[\w-]+)*\s+|'
                     + SSH + r'\s+|eval\s+)(\'[^\']*\'|"(?:\\.|[^"\\])*")')
MAX_DEPTH = 3

HINT = ('等 CI 請改用 `gh-wait run <run-id> -R owner/repo` 或 `gh-wait pr <number> -R owner/repo`'
        '（ETag 條件請求，狀態沒變時 304 不扣額度；放背景跑，結束會通知）。'
        '如果是為了等 checks 過了就合併，考慮 `gh pr merge --auto`。')


def loops(cmd):
    """Yield (keyword, text) for each loop, its text running to its own matching `done`
    (or to the end when unterminated), so nested loops and gh after a loop judge right."""
    blank = QUOTED.sub(lambda m: m.group(0)[0] + ' ' * (len(m.group(0)) - 2) + m.group(0)[-1], cmd)
    open_loops = []
    for m in LOOP_KW.finditer(blank):
        if m.group(1) != 'done':
            open_loops.append((m.group(1), m.start(1)))
        elif open_loops:
            kind, start = open_loops.pop()
            yield kind, cmd[start:m.end(1)]
    for kind, start in open_loops:
        yield kind, cmd[start:]


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
    for kind, body in loops(cmd):
        if not GH_CALL.search(body):
            continue
        args = [a.strip('\'"') for a in SLEEP.findall(body)]
        lits = [LITERAL.fullmatch(a) for a in args]
        sleeps = [float(m.group(1)) * UNIT[m.group(2)] for m in lits if m]
        if sleeps and min(sleeps) < 60:
            return f'用 sleep {min(sleeps):g} 秒的迴圈輪詢 gh，會吃光共用的 5000/hr GitHub 額度。'
        if not all(lits):
            return ('sleep 的間隔是變數或算式，hook 看不出有沒有至少 60 秒；'
                    '用迴圈輪詢 gh 會吃光共用的 5000/hr GitHub 額度。')
        # `for` over a fixed list is a batch, not polling; while/until without sleep spins.
        if not args and kind in ('while', 'until'):
            return '沒有 sleep 的 while／until 迴圈呼叫 gh，會連續狂打共用的 5000/hr GitHub 額度。'
    if depth < MAX_DEPTH:
        for m in PAYLOAD.finditer(cmd):
            inner = m.group(1)[1:-1]
            if m.group(1)[0] == '"':
                inner = re.sub(r'\\([\\"$`])', r'\1', inner)
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
