#!/bin/bash
# Pipe-test gh-quota-guard. Cases are "want|command" per line; want is allow, DENY, or
# DENY:<text the deny reason must contain>. Every run also checks the hook's exit code,
# stderr and output shape (valid deny JSON, or nothing at all). Prints only "ok ..." on success.
H=${1:-$(dirname "$0")/../hooks/gh-quota-guard.py}
export PYTHONDONTWRITEBYTECODE=1
export GH_QUOTA_HOOK_LOG=/dev/null
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0

# check.py HOOK WANT LIMIT MODE TEXT: MODE cmd wraps TEXT as a Bash tool call, raw feeds TEXT as is.
# The hook gets LIMIT seconds (hooks.json gives it 10); prints the problem and exits 1 on failure.
cat > "$tmp/check.py" <<'EOF'
import json, subprocess, sys, time
hook, want, limit, mode, text = sys.argv[1:6]
stdin = text if mode == 'raw' else json.dumps({'tool_name': 'Bash', 'tool_input': {'command': text},
                                               'session_id': 's1', 'cwd': '/w'})
t = time.time()
try:
    p = subprocess.run([sys.executable, hook], input=stdin, capture_output=True, text=True, timeout=float(limit))
except subprocess.TimeoutExpired:
    sys.exit(print(f'took over {limit} s') or 1)
took = time.time() - t
probs = []
if p.returncode != 0:
    probs.append(f'rc={p.returncode}')
if p.stderr:
    probs.append('stderr: ' + p.stderr.strip().splitlines()[-1])
kind, _, sub = want.partition(':')
if kind == 'allow':
    if p.stdout:
        probs.append('got DENY: ' + p.stdout[:200])
else:
    try:
        o = json.loads(p.stdout)['hookSpecificOutput']
        if o['hookEventName'] != 'PreToolUse' or o['permissionDecision'] != 'deny':
            probs.append('bad deny JSON: ' + p.stdout[:200])
        elif not o['permissionDecisionReason'] or sub not in o['permissionDecisionReason']:
            probs.append(f'reason lacks {sub!r}: ' + o['permissionDecisionReason'])
    except (ValueError, KeyError, TypeError):
        probs.append('got allow' if not p.stdout else 'not deny JSON: ' + p.stdout[:200])
if probs:
    sys.exit(print('; '.join(probs)) or 1)
EOF

# run <label> <want> <limit> <mode> <text>
run() {
    local why
    if why=$(python3 "$tmp/check.py" "$H" "$2" "$3" "$4" "$5"); then echo "ok   $2  $1"
    else echo "FAIL want $2 ($why): $1"; fail=1; fi
}

while IFS='|' read -r want cmd; do
    [ -z "$want" ] && continue
    run "$cmd" "$want" 10 cmd "$cmd"
done <<'CASES'
DENY|gh run watch 123 --exit-status
DENY|id=$(gh run list -L1 -q x); gh run watch $id --interval 30
DENY|cd repo && gh pr checks 12 --watch --interval 90
DENY|while ! gh pr view 3 --json state -q .state | grep -q MERGED; do sleep 20; done
DENY|until gh run view 1 --json status -q .status | grep -q completed; do sleep 15; done
DENY|for i in $(seq 30); do gh run view 1 --json status; sleep 10; done
DENY|timeout 1800 gh run watch 123
DENY|timeout --signal=TERM 600 gh pr checks 5 --watch
DENY|nohup gh run watch 1 > /tmp/x &
DENY|ssh ubuntu 'gh run watch 123 -R a/b'
DENY|bash -c "gh run watch 123"
DENY|ssh ubuntu gh run watch 1
DENY|ssh -p 22 -o BatchMode=yes macmini gh pr checks 3 --watch
DENY|sudo gh run watch 1
DENY|time gh run watch 1
DENY|command gh run watch 1
DENY|timeout -k 5 60 gh run watch 1
DENY|echo 1 | xargs -n1 gh run watch
DENY|watch -n 10 gh pr checks 1
DENY|watch gh run view 1
DENY:沒有 sleep|while true; do gh run view 1 --json status; done
DENY|for i in 1 2 3; do gh api x; sleep 30s; done
DENY|curl -s https://api.github.com/repos/a/b/releases/latest
DENY|wget -qO- https://api.github.com/repos/a/b/commits/main
allow|curl -s -H "Authorization: Bearer $(gh auth token)" https://api.github.com/repos/a/b
allow|curl -fsSL https://github.com/a/b/releases/download/v1/x.tar.gz -o x.tgz
DENY|env -u FOO gh run watch 1
DENY|stdbuf -oL gh run watch 1
DENY|curl -H "X: GITHUB_TOKEN_FAKE" https://api.github.com/x
DENY|gh api x; while true; do gh run view 1 --json status; sleep 10; done
DENY|while true; do for x in a b; do echo $x; done; gh run view 1; sleep 5; done
DENY|while true; do echo "done"; gh api x; sleep 10; done
DENY|while true; do echo x-done; gh api x; sleep 10; done
DENY|while true; do gh api x; sleep 10
DENY|nice -10 gh run watch 1
DENY|stdbuf -o L gh run watch 1
allow|for f in a b; do for g in c d; do echo $f$g; done; done; gh api x; sleep 5
allow|curl -s -D - -o /dev/null https://api.github.com/rate_limit
allow|curl -H "Authorization: token $GITHUB_TOKEN" https://api.github.com/x
allow|gh run view 1; while read l; do echo $l; done < f
allow|while true; do gh api x; sleep 90; done; sleep 5
allow|for i in 1 2; do gh api x; done; sleep 5
allow|gh run view 123 --log-failed
allow|for i in 1 2; do gh api x; sleep 2m; done
allow|gh pr comment 1 --body "ready for review"; sleep 3; gh pr view 1
allow|for r in a b; do gh api repos/$r; done
allow|ssh ubuntu gh run view 1
allow|watch -n 5 df -h
allow|[]
allow|gh pr checks 12
allow|gh-wait run 123 -R a/b
allow|while read f; do echo $f; sleep 1; done < x
allow|for i in 1 2; do gh api x; sleep 120; done
allow|git commit -m "replace gh run watch with gh-wait"
allow|timeout 60 gh run view 1
DENY|gh -R o/r run watch 1
DENY|gh --repo o/r pr checks 5 --watch
DENY|gh --repo=o/r run watch 1
DENY|gh pr -R o/r checks 5 --watch
DENY|gh run -Ro/r watch 1
DENY|while true; do gh -R o/r pr view 1; sleep 5; done
DENY|while true; do gh --repo o/r run view 1; sleep 5; done
allow|gh -R o/r run view 1
DENY|bash -lc 'while true; do gh run view 1; sleep 5; done'
DENY|sh -c "until gh pr view 1 --json state | grep -q MERGED; do sleep 10; done"
DENY|ssh ubuntu 'while true; do gh api x; sleep 5; done'
DENY|ssh -p 22 -o BatchMode=yes ubuntu "cd r && while true; do gh run view 1; sleep 5; done"
DENY|ssh ubuntu bash -c 'while true; do gh api x; sleep 5; done'
DENY|eval 'while true; do gh api x; sleep 5; done'
DENY|bash -c "for i in \$(seq 9); do gh api \"x\"; sleep 5; done"
DENY|ssh ubuntu 'curl -s https://api.github.com/x'
allow|bash -c 'for i in 1 2; do gh api x; done'
allow|ssh ubuntu 'while true; do gh api x; sleep 90; done'
allow|git commit -m "while true; do gh api x; sleep 5; done"
DENY|while true; do gh issue list; sleep 5; done
DENY|while true; do gh workflow view x; sleep 5; done
DENY|while true; do gh release view; sleep 5; done
DENY|while true; do gh search prs foo; sleep 5; done
DENY|while true; do /opt/homebrew/bin/gh run view 1; sleep 5; done
DENY|/opt/homebrew/bin/gh run watch 1
DENY|/usr/bin/gh pr checks 1 --watch
allow|while true; do gh config get editor; sleep 5; done
allow|while true; do gh auth status; sleep 5; done
allow|while true; do gh-wait run 1 -R a/b && break; done
DENY|echo "$GITHUB_TOKEN"; curl https://api.github.com/repos/a/b
DENY|curl -s https://api.github.com/repos/x/y | grep authorization:
DENY|curl https://API.GITHUB.COM/repos/a/b
DENY|curl -s https://api.github.com/x; echo $GH_TOKEN
DENY|T=$(gh auth token); curl https://api.github.com/x
allow|curl -s https://api.github.com/repos/a/b -H "Authorization: token $T"
allow|T=$(gh auth token); curl -H "Authorization: token $T" https://api.github.com/x
DENY:變數|while true; do gh run view 1; sleep "$N"; done
DENY:變數|while true; do gh run view 1; sleep $N; done
DENY:變數|for i in 1 2 3; do gh api x; sleep $((i * 30)); done
DENY:sleep 5 秒|while true; do gh api x; sleep "5"; done
allow|while true; do gh api x; sleep "120"; done
DENY|ssh -o "StrictHostKeyChecking no" ubuntu gh run watch 1
DENY|ssh -o 'StrictHostKeyChecking no' ubuntu gh run watch 1
DENY|ssh -o "ProxyCommand=ssh -W %h:%p jump" ubuntu gh run watch 1
DENY|ssh -o ProxyCommand="ssh -W %h:%p jump" ubuntu gh run watch 1
DENY|ssh -o "StrictHostKeyChecking no" ubuntu 'while true; do gh api x; sleep 5; done'
allow|ssh -o "StrictHostKeyChecking no" ubuntu gh run view 1
allow|while read r; do gh repo view "$r"; done < repos.txt
allow|gh issue list --json number -q ".[].number" | while read n; do gh issue view $n; done
allow|while IFS= read -r r; do gh api "repos/$r"; done < repos.txt
allow|while read l; do echo "gh is $l"; done < f
allow|while true; do echo "gh is up"; sleep 5; done
allow|git commit -m "guard: catch polling inside (bash -c 'while true; do gh api x; sleep 5; done') too"
allow|echo "ssh ubuntu 'while true; do gh api x; sleep 5; done'"
DENY:sleep 5 秒|while read r; do gh api "repos/$r"; sleep 5; done < repos.txt
DENY:沒有 sleep|while true; do read x; gh api "$x"; done
DENY|while true; do echo "$(gh run view 1 --json status)"; sleep 5; done
DENY|while true; do ssh ubuntu "gh api x"; sleep 5; done
CASES

# Multi-line commands: backslash continuation keeps one curl; heredoc bodies are text, not commands.
run "curl URL \\ newline -H Authorization \$(gh auth token)" allow 10 cmd $'curl -s https://api.github.com/repos/a/b \\\n  -H "Authorization: Bearer $(gh auth token)"'
run "curl URL \\ newline -H Authorization \$GH_TOKEN" allow 10 cmd $'curl -s https://api.github.com/repos/a/b \\\n  -H "Authorization: token $GH_TOKEN"'
run "curl URL \\ newline -o (no token)" DENY 10 cmd $'curl -s https://api.github.com/repos/a/b \\\n  -o out.json'
run "curl URL newline echo \$GH_TOKEN (no continuation)" DENY 10 cmd $'curl -s https://api.github.com/repos/a/b\necho $GH_TOKEN'
run "git commit -F - heredoc quoting bash -c polling" allow 10 cmd $'git commit -F - <<\'EOF\'\nguard: catch polling inside (bash -c \'while true; do gh api x; sleep 5; done\') too\nEOF'
run "bash heredoc script polling gh" DENY 10 cmd $'bash <<\'EOF\'\nwhile true; do gh api x; sleep 5; done\nEOF'
# A here-string (<<<) is not a heredoc: the lines after it are still commands.
run "here-string word, then bash -c polling" DENY 10 cmd $'cat <<< text\nbash -c \'while true; do gh api user; sleep 5; done\''
run "here-string word, then plain polling loop" DENY 10 cmd $'grep x <<< hello\nwhile true; do gh api user; sleep 5; done'

# Malformed input: the hook must exit 0 with no output, never crash.
for raw in '' 'notjson' '[]' '{}' '"x"' '{"tool_input":"x"}' '{"tool_input":{"command":5}}' '{"tool_input":null}'; do
    run "raw stdin: $raw" allow 10 raw "$raw"
done

# Catastrophic backtracking: prose that repeats wrapper words must finish fast (the engine kills the hook at 10 s).
p1='' p2='' p3='' p4='' p5='' p6=''
for i in $(seq 40); do
    p1="$p1 ssh host$i gh uptime,"; p2="$p2 ssh"; p3="$p3 env -u"; p4="$p4 stdbuf -o"
    p5="$p5 ssh -o \"a b\""; p6="$p6 ssh -o 'x"
done
run "echo \"ssh hostN gh uptime, ...\" x40" allow 2 cmd "echo \"$p1 gh\""
run "bare ssh x40" allow 2 cmd "$p2 gh"
run "env -u x40" allow 2 cmd "$p3 gh"
run "stdbuf -o x40" allow 2 cmd "$p4 gh"
run "for loop over ssh x40 prose" allow 2 cmd "for l in a; do echo \"$p1\"; done"
run "ssh -o \"a b\" x40" allow 2 cmd "$p5 gh"
run "ssh -o 'x (unbalanced) x40" allow 2 cmd "$p6 gh"
run "while read over ssh -o \"a b\" x40 prose" allow 2 cmd "while read l; do echo '$p5'; done < f"

# Logging: one JSON line per deny with the documented keys; rotate to hook.log.1 past 1 MB.
log="$tmp/state/hook.log"
long="gh run watch 1 $(printf 'x%.0s' $(seq 600))"
GH_QUOTA_HOOK_LOG=$log run "log: deny writes one line" DENY 10 cmd "$long"
if why=$(python3 - "$log" <<'EOF'
import json, sys
lines = open(sys.argv[1], encoding='utf-8').read().splitlines()
assert len(lines) == 1, f'{len(lines)} lines'
e = json.loads(lines[0])
assert set(e) == {'ts', 'host', 'session', 'cwd', 'reason', 'cmd'}, sorted(e)
assert e['session'] == 's1' and e['cwd'] == '/w', (e['session'], e['cwd'])
assert e['reason'] and '，' not in e['reason'] and 'gh-wait' not in e['reason'], e['reason']
assert len(e['cmd']) == 500 and e['cmd'].startswith('gh run watch 1 x'), len(e['cmd'])
EOF
); then echo "ok   log: keys, reason before '，', cmd capped at 500"; else echo "FAIL log line: $why"; fail=1; fi
python3 -c 'import sys; open(sys.argv[1], "a").write("y" * 1000001)' "$log"
GH_QUOTA_HOOK_LOG=$log run "log: deny past 1 MB" DENY 10 cmd "gh run watch 2"
if [ "$(wc -l < "$log" | tr -d ' ')" = 1 ] && [ "$(wc -c < "${log}.1" | tr -d ' ')" -gt 1000000 ]; then
    echo "ok   log: rotated to hook.log.1"
else echo "FAIL log: not rotated past 1 MB"; fail=1; fi
GH_QUOTA_HOOK_LOG=$log run "log: allow writes nothing" allow 10 cmd "gh run view 1"
[ "$(wc -l < "$log" | tr -d ' ')" = 1 ] && echo "ok   log: allow left the log alone" || { echo "FAIL log: allow wrote a line"; fail=1; }
exit $fail
