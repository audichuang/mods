#!/bin/bash
# Pipe-test gh-quota-guard: "want|command" per line.
H=${1:-$(dirname "$0")/../hooks/gh-quota-guard.py}
fail=0
while IFS='|' read -r want cmd; do
    [ -z "$want" ] && continue
    out=$(python3 -c 'import json,sys;print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$cmd" | python3 "$H")
    got=allow; [ -n "$out" ] && got=DENY
    if [ "$got" = "$want" ]; then echo "ok   $want  $cmd"; else echo "FAIL want $want got $got: $cmd"; fail=1; fi
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
DENY|while true; do gh run view 1 --json status; done
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
CASES
exit $fail
