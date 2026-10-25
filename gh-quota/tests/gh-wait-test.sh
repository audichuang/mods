#!/bin/bash
# Test bin/gh-wait against a fake `gh` first on PATH that serves canned `gh api -i` answers.
# Prints only "ok ..." lines on success.
GW=$(cd "$(dirname "$0")/../bin" && pwd)/gh-wait
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
S=$T/stub
mkdir -p "$T/bin" "$T/nojq" "$S"
# BASH_ENV may re-prepend /opt/homebrew/bin and shadow the stub with the real gh.
unset BASH_ENV
export PATH="$T/bin:$PATH" GHS=$S GH_WAIT_MINUTE=2 GH_WAIT_BEAT=300
fail=0

# The fake gh: call N answers from $GHS/N.out (stdout), N.err (stderr), N.rc (exit code, default 0);
# a call with no files repeats the last numbered answer. Every call's argv is appended to $GHS/argv.
cat > "$T/bin/gh" <<'EOF'
#!/bin/bash
n=$(( $(cat "$GHS/n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$GHS/n"
printf '%s\n' "$*" >> "$GHS/argv"
k=$n
while [ "$k" -gt 1 ] && [ ! -e "$GHS/$k.out" ] && [ ! -e "$GHS/$k.rc" ]; do k=$((k - 1)); done
[ -e "$GHS/$k.out" ] && cat "$GHS/$k.out"
[ -e "$GHS/$k.err" ] && cat "$GHS/$k.err" >&2
exit "$(cat "$GHS/$k.rc" 2>/dev/null || echo 0)"
EOF
chmod +x "$T/bin/gh"
cp "$T/bin/gh" "$T/nojq/gh"

fresh() { rm -rf "$S"; mkdir -p "$S"; }
# resp <n> <status> <body> [header ...]: the n-th answer as `gh api -i` prints it (CRLF headers).
resp() {
    local n=$1 st=$2 body=$3 h; shift 3
    { printf 'HTTP/2.0 %s\r\n' "$st"; for h in "$@"; do printf '%s\r\n' "$h"; done; printf '\r\n%s\n' "$body"; } > "$S/$n.out"
}
# gw <seconds> <args...>: run gh-wait (PATH=$GWPATH if set) under /bin/bash with a hard limit; sets rc, out, err.
gw() {
    local limit=$1 pid killer; shift
    PATH=${GWPATH:-$PATH} /bin/bash "$GW" "$@" > "$T/out" 2> "$T/err" & pid=$!
    ( sleep "$limit"; kill "$pid" ) > /dev/null 2>&1 & killer=$!
    wait "$pid" 2> /dev/null; rc=$?
    kill "$killer" 2> /dev/null; wait "$killer" 2> /dev/null
    out=$(cat "$T/out"); err=$(cat "$T/err")
}
# check <name> <want-rc> [stdout-has|stdout-lacks|stderr-has|stderr-lacks|argv-has|argv-lacks|calls]=<text> ...
check() {
    local name=$1 want=$2 c why=''; shift 2
    [ "$rc" = "$want" ] || why="rc $rc, want $want"
    for c in "$@"; do
        case $c in
            stdout-has=*) grep -qF -- "${c#*=}" <<< "$out" || why="$why; stdout lacks '${c#*=}'" ;;
            stderr-has=*) grep -qF -- "${c#*=}" <<< "$err" || why="$why; stderr lacks '${c#*=}'" ;;
            stdout-lacks=*) grep -qF -- "${c#*=}" <<< "$out" && why="$why; stdout has '${c#*=}'" ;;
            stderr-lacks=*) grep -qF -- "${c#*=}" <<< "$err" && why="$why; stderr has '${c#*=}'" ;;
            argv-has=*) grep -qF -- "${c#*=}" "$S/argv" || why="$why; no gh call had '${c#*=}'" ;;
            argv-lacks=*) grep -qF -- "${c#*=}" "$S/argv" && why="$why; a gh call had '${c#*=}'" ;;
            calls=*) [ "$(wc -l < "$S/argv" | tr -d ' ')" = "${c#*=}" ] || why="$why; $(wc -l < "$S/argv" | tr -d ' ') gh calls, want ${c#*=}" ;;
        esac
    done
    if [ -z "$why" ]; then echo "ok   $name"
    else echo "FAIL $name: ${why#; }"; echo "  stdout: $out"; echo "  stderr: $err"; fail=1; fi
}

RUN_WAIT='{"status":"in_progress","conclusion":null}'
RUN_OK='{"status":"completed","conclusion":"success"}'
RUNS_OK='{"check_runs":[{"name":"lint","status":"completed","conclusion":"success"}]}'
SUITES_RUNNING='{"check_suites":[{"app":{"name":"GitHub Actions"},"status":"in_progress","latest_check_runs_count":1}]}'
SUITES_DONE='{"check_suites":[{"app":{"name":"GitHub Actions"},"status":"completed","latest_check_runs_count":2}]}'

fresh
resp 1 '200 OK' "$RUN_WAIT" 'Etag: W/"abc"'
resp 2 '304 Not Modified' ''
resp 3 '200' "$RUN_OK" 'Etag: W/"def"'
gw 20 run 7 -R o/r -i 1
check "run: in_progress, 304, success" 0 stdout-has=wait:in_progress stdout-has=ok \
    'argv-has=If-None-Match: W/"abc"' argv-has=repos/o/r/actions/runs/7 calls=3

fresh
resp 1 '200 OK' '{"status":"completed","conclusion":"failure"}'
echo 'failed jobs: build (failure)' > "$S/2.out"
gw 20 run 7 -R o/r -i 1
check "run: failure lists failed jobs" 1 stdout-has=fail:failure 'stdout-has=failed jobs: build (failure)' \
    argv-has=repos/o/r/actions/runs/7/jobs

fresh
echo abc123 > "$S/1.out"
resp 2 '200 OK' '{"total_count":0,"check_runs":[]}' 'ETag: "e1"'
resp 3 '200 OK' '{"check_runs":[{"name":"ci","status":"in_progress","conclusion":null},{"name":"lint","status":"completed","conclusion":"success"}]}' 'ETag: "e2"'
resp 4 '200 OK' '{"check_runs":[{"name":"ci","status":"completed","conclusion":"success"},{"name":"lint","status":"completed","conclusion":"skipped"}]}'
resp 5 '200 OK' "$SUITES_DONE"
gw 20 pr 5 -R o/r -i 1
check "pr: no checks, running, ok" 0 'stdout-has=wait:no checks yet' 'stdout-has=wait:1 running (ci)' stdout-has=ok \
    argv-has=repos/o/r/pulls/5 argv-has=repos/o/r/commits/abc123/check-runs 'argv-has=If-None-Match: "e1"' \
    argv-has=repos/o/r/commits/abc123/check-suites calls=5

# A job with needs: has no check run until the jobs it needs finish, so every existing run can be
# green while its workflow (check suite) is still in progress.
fresh
echo abc123 > "$S/1.out"
resp 2 '200 OK' "$RUNS_OK" 'ETag: "e1"'
resp 3 '200 OK' "$SUITES_RUNNING"
resp 4 '200 OK' '{"check_runs":[{"name":"lint","status":"completed","conclusion":"success"},{"name":"test","status":"in_progress","conclusion":null}]}' 'ETag: "e2"'
resp 5 '200 OK' '{"check_runs":[{"name":"lint","status":"completed","conclusion":"success"},{"name":"test","status":"completed","conclusion":"success"}]}' 'ETag: "e3"'
resp 6 '200 OK' "$SUITES_DONE"
gw 20 pr 5 -R o/r -i 1
check "pr: green runs but suite in progress waits for the suite" 0 'stdout-has=wait:1 workflow still running' \
    'stdout-has=wait:1 running (test)' stdout-has=ok argv-has=repos/o/r/commits/abc123/check-suites calls=6

# After the downgrade the stored ETag must go, or the next poll gets 304 and never re-checks the suites.
fresh
echo abc123 > "$S/1.out"
resp 2 '200 OK' "$RUNS_OK" 'ETag: "e1"'
resp 3 '200 OK' "$SUITES_RUNNING"
resp 4 '200 OK' "$RUNS_OK" 'ETag: "e1"'
resp 5 '200 OK' "$SUITES_DONE"
gw 20 pr 5 -R o/r -i 1
check "pr: downgrade to wait clears the ETag" 0 'stdout-has=wait:1 workflow still running' stdout-has=ok \
    argv-lacks=If-None-Match calls=5

fresh
echo abc123 > "$S/1.out"
resp 2 '200 OK' "$RUNS_OK"
resp 3 '200 OK' '{"check_suites":[{"app":{"name":"Some App"},"status":"queued","latest_check_runs_count":0},{"app":{"name":"GitHub Actions"},"status":"completed","latest_check_runs_count":1}]}'
gw 20 pr 5 -R o/r -i 1
check "pr: queued suite with no runs is ignored" 0 stdout-has=ok stdout-lacks=wait calls=3

fresh
echo abc123 > "$S/1.out"
resp 2 '200 OK' "$RUNS_OK"
resp 3 '502 Bad Gateway' '{"message":"Server Error"}'
echo 'gh: Server Error (HTTP 502)' > "$S/3.err"; echo 1 > "$S/3.rc"
resp 4 '200 OK' "$RUNS_OK"
resp 5 '200 OK' "$SUITES_DONE"
gw 20 pr 5 -R o/r -i 1
check "pr: check-suites error is not ok, retried" 0 'stderr-has=HTTP 502' stdout-has=ok calls=5

fresh
echo abc123 > "$S/1.out"
resp 2 '200 OK' "$RUNS_OK"
printf 'To get started with GitHub CLI, please run:  gh auth login\n' > "$S/3.err"; echo 4 > "$S/3.rc"
gw 20 pr 5 -R o/r -i 1
check "pr: check-suites not logged in stops" 2 'stderr-has=gh auth login' calls=3

fresh
echo abc123 > "$S/1.out"
resp 2 '200 OK' '{"check_runs":[{"name":"ci","status":"completed","conclusion":"success"},{"name":"lint","status":"completed","conclusion":"failure"}]}'
gw 20 pr 5 -R o/r -i 1
check "pr: failure names the check" 1 stdout-has=fail:lint calls=2

fresh
resp 1 '200 OK' "$RUN_WAIT" 'Etag: W/"abc"'
resp 2 '304 Not Modified' ''
GH_WAIT_BEAT=1 GH_WAIT_MINUTE=5 gw 20 run 7 -R o/r -i 1 -t 1
check "timeout: -t 1 (GH_WAIT_MINUTE=5), heartbeat" 2 'stderr-has=timeout after 1 min, last state: wait:in_progress' \
    'stdout-has=unchanged for'

fresh
resp 1 '404 Not Found' '{"message":"Not Found"}'
echo 'gh: Not Found (HTTP 404)' > "$S/1.err"; echo 1 > "$S/1.rc"
gw 20 run 7 -R o/r -i 1
check "404: exits at once" 2 'stderr-has=HTTP 404' calls=1

fresh
printf 'To get started with GitHub CLI, please run:  gh auth login\n' > "$S/1.err"; echo 4 > "$S/1.rc"
gw 20 run 7 -R o/r -i 1
check "not logged in: says so, no retries" 2 'stderr-has=gh auth login' stderr-lacks=HTTP calls=1

fresh
echo 'error connecting to api.github.com' > "$S/1.err"; echo 1 > "$S/1.rc"
resp 2 '200 OK' "$RUN_OK"
gw 20 run 7 -R o/r -i 1
check "network error: shown, retried" 0 'stderr-has=error connecting to api.github.com' stdout-has=ok calls=2

fresh
resp 1 '502 Bad Gateway' '{"message":"Server Error"}'
echo 'gh: Server Error (HTTP 502)' > "$S/1.err"; echo 1 > "$S/1.rc"
resp 2 '200 OK' "$RUN_OK"
gw 20 run 7 -R o/r -i 1
check "502: retried" 0 'stderr-has=HTTP 502 (attempt 1)' stdout-has=ok

fresh
resp 1 '403 Forbidden' '{"message":"API rate limit exceeded"}' 'X-Ratelimit-Remaining: 0' "X-Ratelimit-Reset: $(( $(date +%s) + 1 ))"
echo 'gh: API rate limit exceeded (HTTP 403)' > "$S/1.err"; echo 1 > "$S/1.rc"
resp 2 '200 OK' "$RUN_OK"
gw 20 run 7 -R o/r -i 1
check "rate limit: waits for reset, not an error" 0 'stderr-has=rate limit' stderr-lacks=attempt stdout-has=ok

fresh
for n in 1 2 3 4 5; do echo 'error connecting to api.github.com' > "$S/$n.err"; echo 1 > "$S/$n.rc"; done
GH_WAIT_MINUTE=60 gw 30 run 7 -R o/r -i 1
check "5 errors in a row: gives up" 2 'stderr-has=(attempt 5)' calls=5

fresh
GWPATH=$T/nojq gw 10 run 7 -R o/r
check "no jq: says so before calling gh" 2 'stderr-has=jq is required'
[ -e "$S/argv" ] && { echo "FAIL no jq: gh was called"; fail=1; }

fresh
gw 10 run 7 -R o/r -i 0
check "usage: -i 0" 2 stderr-has=gh-wait
gw 10 run 7 -R
check "usage: -R without value" 2 stderr-has=gh-wait
gw 10 job 7 -R o/r
check "usage: unknown kind" 2 stderr-has=gh-wait
exit $fail
