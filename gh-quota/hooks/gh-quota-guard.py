#!/usr/bin/env python3
# PreToolUse(Bash): block GitHub API polling patterns that burn the shared 5000/hr quota,
# and point the agent at gh-wait (ETag conditional requests; 304s are free).
import json
import re
import sys

# Command position: start of line or after ; & | ( ! quote `$(` do/then/while/until/if,
# then optional VAR=x and wrappers. Quotes count so that `ssh host 'gh run watch'` and
# `bash -c "..."` are caught (the remote side has no hook); the cost is that prose in a
# quoted string starting with `gh run watch` is blocked too.
SEP = r'(?:^|[;&|(!\n"\']|\$\(|\b(?:do|then|while|until|if)\b)\s*'
WRAP = (r'(?:\w+=\S*\s+'
        r'|timeout\s+(?:-\S+\s+(?:\d\S*\s+)?)*\S+\s+'
        r'|nice\s+(?:-n\s*-?\d+\s+|-\d+\s+)?|env\s+(?:-u\s+\S+\s+|-\S+\s+)*'
        r'|stdbuf\s+(?:-[ioe]\s+\S+\s+|-\S+\s+)*'
        r'|xargs\s+(?:-\S+\s+(?:\d+\s+)?)*'
        r'|ssh\s+[^;&|\n]*?\s'
        r'|(?:nohup|sudo|time|command|exec)\s+)*')
POS = SEP + WRAP
WATCH = re.compile(POS + r'gh\s+run\s+watch\b')
CHECKS = re.compile(POS + r'gh\s+pr\s+checks\b[^;&|\n]*--watch')
# watch(1) re-runs its command forever, every 2 s by default.
WATCH_CMD = re.compile(POS + r'watch\b[^;&|\n]*\bgh\s')
# Loop keywords and `done` at command position; matched on a copy with quoted text blanked,
# so `echo "done"` or `x-done` never closes a loop.
LOOP_KW = re.compile(r'(?:^|[;&|(\n]|\bdo\b|\bthen\b|\belse\b)\s*(while|until|for|done)\b')
QUOTED = re.compile(r"'[^']*'|\"(?:\\.|[^\"\\])*\"")
GH_CALL = re.compile(POS + r'gh\s+(?:api|run|pr)\b')
SLEEP = re.compile(r'\bsleep\s+(\d+(?:\.\d+)?)([smhd]?)\b')
UNIT = {'': 1, 's': 1, 'm': 60, 'h': 3600, 'd': 86400}
# Anonymous REST calls share the exit IP's 60/hr; `gh api` uses the account's 5000/hr.
ANON_CURL = re.compile(POS + r'(?:curl|wget)\b[^;&|\n]*api\.github\.com')
AUTH = re.compile(r'(?i)authorization:|\$\(gh auth token\)|\$\{?(?:GITHUB_TOKEN|GH_TOKEN)\b')

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


def reason(cmd):
    if WATCH.search(cmd):
        return '`gh run watch` 每輪打 2 個請求加每個執行中 job 1 個，會吃光共用的 5000/hr GitHub 額度。'
    if CHECKS.search(cmd):
        return '`gh pr checks --watch` 是固定間隔輪詢，會吃光共用的 5000/hr GitHub 額度。'
    if ANON_CURL.search(cmd) and not AUTH.search(cmd):
        return ('沒帶 token 的 curl／wget 打 api.github.com，吃的是出口 IP 共用的每小時 60 次匿名額度；'
                '改用 `gh api <path>`（走帳號的 5000 次）。')
    if WATCH_CMD.search(cmd):
        return '`watch … gh` 會每隔幾秒重跑 gh，會吃光共用的 5000/hr GitHub 額度。'
    for kind, body in loops(cmd):
        if not GH_CALL.search(body):
            continue
        sleeps = [float(n) * UNIT[u] for n, u in SLEEP.findall(body)]
        if sleeps and min(sleeps) < 60:
            return f'用 sleep {min(sleeps):g} 秒的迴圈輪詢 gh，會吃光共用的 5000/hr GitHub 額度。'
        # `for` over a fixed list is a batch, not polling; while/until without sleep spins.
        if not sleeps and kind in ('while', 'until'):
            return '沒有 sleep 的 while／until 迴圈呼叫 gh，會連續狂打共用的 5000/hr GitHub 額度。'
    return None


def main():
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return
    if not isinstance(data, dict):
        return
    cmd = (data.get('tool_input') or {}).get('command') or ''
    why = reason(cmd)
    if why:
        json.dump({'hookSpecificOutput': {
            'hookEventName': 'PreToolUse',
            'permissionDecision': 'deny',
            'permissionDecisionReason': why + HINT,
        }}, sys.stdout, ensure_ascii=False)


if __name__ == '__main__':
    main()
