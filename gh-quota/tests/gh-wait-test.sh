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
# SSH alias resolution is local and independent of the machine's SSH config.
export GH_WAIT_SSH="$T/bin/ssh-config"
cat > "$GH_WAIT_SSH" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$GHS/ssh.argv"
case ${!#} in
    github-audi) echo 'hostname github.com' ;;
    *) echo 'hostname gitlab.com' ;;
esac
EOF
chmod +x "$GH_WAIT_SSH"

# The fake gh: call N answers from $GHS/N.out (stdout), N.err (stderr), N.rc (exit code, default 0);
# a call with no files repeats the last numbered answer. Jobs use jobs.N.out/rc/err
# (default empty jobs); every call, including jobs, is appended to $GHS/argv.
cat > "$T/bin/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$GHS/argv"
allow_escapes=0
for arg in "$@"; do [ "$arg" != --allow-escape-sequences ] || allow_escapes=1; done
for arg in "$@"; do
    case $arg in
        repos/*/pulls\?*)
            owner=${arg#repos/}; owner=${owner%%/*}
            if [ -e "$GHS/prlist.$owner.out" ]; then cat "$GHS/prlist.$owner.out"; exit 0; fi ;;
        repos/*/actions/workflows/*/runs*)
            if [ -e "$GHS/wfruns.out" ]; then cat "$GHS/wfruns.out"; exit 0; fi ;;
        repos/*/check-runs*)
            if [ -e "$GHS/checks.out" ]; then cat "$GHS/checks.out"; exit 0; fi ;;
        repos/*/check-suites*)
            if [ -e "$GHS/suites.out" ]; then cat "$GHS/suites.out"; exit 0; fi ;;
    esac
    case $arg in
        repos/*/*/*) ;;
        repos/*/*)
            if [ -e "$GHS/repo.out" ]; then cat "$GHS/repo.out"; else printf 'HTTP/2.0 200 OK\r\n\r\n{}\n'; fi
            exit 0 ;;
    esac
    case $arg in
        repos/*/actions/jobs/*/logs)
            if [ -e "$GHS/old-gh" ] && [ "$allow_escapes" = 1 ]; then
                echo 'unknown flag: --allow-escape-sequences' >&2; exit 1
            fi
            if [ ! -e "$GHS/old-gh" ] && [ "$allow_escapes" = 0 ]; then
                echo 'the response contains terminal escape sequences; pass --allow-escape-sequences to output it anyway' >&2
                exit 1
            fi
            id=${arg%/logs}; id=${id##*/}
            [ -e "$GHS/log.$id.out" ] && cat "$GHS/log.$id.out"
            [ -e "$GHS/log.$id.err" ] && cat "$GHS/log.$id.err" >&2
            exit "$(cat "$GHS/log.$id.rc" 2>/dev/null || echo 0)"
            ;;
    esac
done
if [[ $* == *actions/runs/*/jobs?* ]]; then
    j=$(( $(cat "$GHS/j" 2>/dev/null || echo 0) + 1 )); echo "$j" > "$GHS/j"
    while [ "$j" -gt 1 ] && [ ! -e "$GHS/jobs.$j.out" ] && [ ! -e "$GHS/jobs.$j.rc" ]; do j=$((j - 1)); done
    if [ -e "$GHS/jobs.$j.out" ]; then cat "$GHS/jobs.$j.out"; else echo '{"jobs":[]}'; fi
    [ -e "$GHS/jobs.$j.err" ] && cat "$GHS/jobs.$j.err" >&2
    exit "$(cat "$GHS/jobs.$j.rc" 2>/dev/null || echo 0)"
fi
n=$(( $(cat "$GHS/n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$GHS/n"
k=$n
while [ "$k" -gt 1 ] && [ ! -e "$GHS/$k.out" ] && [ ! -e "$GHS/$k.rc" ]; do k=$((k - 1)); done
[ -e "$GHS/$k.out" ] && cat "$GHS/$k.out"
[ -e "$GHS/$k.err" ] && cat "$GHS/$k.err" >&2
exit "$(cat "$GHS/$k.rc" 2>/dev/null || echo 0)"
EOF
chmod +x "$T/bin/gh"
cp "$T/bin/gh" "$T/nojq/gh"

fresh() {
    rm -rf "$S"; mkdir -p "$S"; : > "$S/argv"
    # The older fork/upstream cases have no fork-local PR.
    resp prlist.fork '200 OK' '[]'
}
# resp <n> <status> <body> [header ...]: the n-th answer as `gh api -i` prints it (CRLF headers).
resp() {
    local n=$1 st=$2 body=$3 h; shift 3
    { printf 'HTTP/2.0 %s\r\n' "$st"; for h in "$@"; do printf '%s\r\n' "$h"; done; printf '\r\n%s\n' "$body"; } > "$S/$n.out"
}
jobs_resp() { printf '%s\n' "$2" > "$S/jobs.$1.out"; }
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
            ssh-has=*) grep -qF -- "${c#*=}" "$S/ssh.argv" 2>/dev/null || why="$why; no SSH config lookup had '${c#*=}'" ;;
            argv-has=*) grep -qF -- "${c#*=}" "$S/argv" || why="$why; no gh call had '${c#*=}'" ;;
            argv-exact-lacks=*) grep -qxF -- "${c#*=}" "$S/argv" && why="$why; gh called '${c#*=}'" ;;
            argv-lacks=*) grep -qF -- "${c#*=}" "$S/argv" && why="$why; a gh call had '${c#*=}'" ;;
            calls=*) [ "$(wc -l < "$S/argv" | tr -d ' ')" = "${c#*=}" ] || why="$why; $(wc -l < "$S/argv" | tr -d ' ') gh calls, want ${c#*=}" ;;
        esac
    done
    if [ -z "$why" ]; then echo "ok   $name"
    else echo "FAIL $name: ${why#; }"; echo "  stdout: $out"; echo "  stderr: $err"; fail=1; fi
}

CHECK_SHA=abc1230000000000000000000000000000000000
RUN_WAIT='{"status":"in_progress","conclusion":null}'
RUN_OK='{"status":"completed","conclusion":"success"}'
RUNS_OK='{"check_runs":[{"name":"lint","status":"completed","conclusion":"success"}]}'
SUITES_RUNNING='{"check_suites":[{"app":{"name":"GitHub Actions"},"status":"in_progress","latest_check_runs_count":1}]}'
SUITES_DONE='{"check_suites":[{"app":{"name":"GitHub Actions"},"status":"completed","conclusion":"success","latest_check_runs_count":2}]}'

# Failed-job excerpts end at the first error annotation, before cleanup noise.
fresh
resp 1 '200 OK' '{"status":"completed","conclusion":"failure"}'
jobs_resp 1 '{"jobs":[{"id":11,"name":"build","status":"completed","conclusion":"failure"}]}'
cat > "$S/log.11.out" <<'EOF'
2026-11-15T00:22:02.2988291Z setup-dropped
2026-11-15T00:22:02.2992766Z   2 failed
2026-11-15T00:22:02.2993515Z     settings.spec.ts:83 installs a tool with progress
2026-11-15T00:22:02.2994372Z     settingsPaneLayout.spec.ts:10 keeps details usable
2026-11-15T00:22:02.2994833Z   103 passed (5.6m)
2026-11-15T00:22:02.4234723Z [ELIFECYCLE] Command failed with exit code 1.
2026-11-15T00:22:02.5456673Z ##[error]Process completed with exit code 1.
2026-11-15T00:22:02.5508309Z [command]/usr/bin/git config --local --unset-all cleanup-noise
2026-11-15T00:22:02.5508502Z ##[error]second-error-must-not-win
2026-11-15T00:22:02.5508632Z docker rm --force cleanup-container
EOF
gw 10 run 7 -R o/r --log-lines 6 -i 1
check "logs: first error excerpt contains failure context and excludes cleanup" 1 \
    'stdout-has=2 failed' stdout-has=settings.spec.ts:83 stdout-has=settingsPaneLayout.spec.ts:10 \
    'stdout-has=103 passed' 'stdout-has=Command failed with exit code 1.' \
    'stdout-has=##[error]Process completed with exit code 1.' \
    stdout-lacks=setup-dropped stdout-lacks=cleanup-noise stdout-lacks=cleanup-container \
    stdout-lacks=second-error-must-not-win stdout-lacks=2026-11-15T calls=3
[ "$(tail -n 1 "$T/out")" = '##[error]Process completed with exit code 1.' ] || {
    echo 'FAIL logs: excerpt did not end at the first error'; fail=1;
}

fresh
resp 1 '200 OK' '{"status":"completed","conclusion":"failure"}'
jobs_resp 1 '{"jobs":[{"id":11,"name":"build","status":"completed","conclusion":"failure"}]}'
printf '2026-11-15T00:22:02.2990302Z ordinary error message before tail\n2026-11-15T00:22:02.2991408Z fallback-first\n2026-11-15T00:22:02.2992274Z fallback-last\n' > "$S/log.11.out"
gw 10 run 7 -R o/r --log-lines 2 -i 1
check "logs: no error annotation falls back to the last N timestamp-free lines" 1 \
    stdout-has=fallback-first stdout-has=fallback-last 'stdout-lacks=ordinary error' \
    stdout-lacks=2026-11-15T calls=3

# Real gh refuses Actions log escapes unless explicitly allowed; output stays plain.
for gh_age in current old; do
    fresh
    [ "$gh_age" != old ] || : > "$S/old-gh"
    resp 1 '200 OK' '{"status":"completed","conclusion":"failure"}'
    jobs_resp 1 '{"jobs":[{"id":11,"name":"build","status":"completed","conclusion":"failure"}]}'
    printf '2026-11-15T00:00:01Z first-dropped\n2026-11-15T00:00:02Z \033[31mred error\033[0m\r\n2026-11-15T00:00:03Z \033]0;hidden-title\007plain \033]8;;https://hidden.example\033\\link\033]8;;\033\\\r\n' > "$S/log.11.out"
    expected_calls=3
    [ "$gh_age" != old ] || expected_calls=4
    gw 10 run 7 -R o/r --log-lines 2 -i 1
    check "logs: $gh_age gh yields plain ANSI/OSC/CR-free tail" 1 \
        'stdout-has=red error' 'stdout-has=plain link' stdout-lacks=first-dropped \
        stdout-lacks=hidden-title stdout-lacks=hidden.example "stdout-lacks=$(printf '\033')" \
        "stdout-lacks=$(printf '\r')" "stdout-lacks=$(printf '\007')" argv-has=--allow-escape-sequences \
        'stderr-lacks=terminal escape sequences' 'stderr-lacks=unknown flag' calls="$expected_calls"
    if [ "$gh_age" = old ]; then
        check "logs: unknown flag retries once without it" 1 \
            'argv-has=api repos/o/r/actions/jobs/11/logs' calls=4
    fi
done

# Auto -> commit must find tag runs even while the checkout stays on pushed main.
TAG_REPO=$T/main-tag
git -C "$T" init -q -b main "$TAG_REPO"
git -C "$TAG_REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m tag-run
git -C "$TAG_REPO" remote add origin https://github.com/o/r.git
git -C "$TAG_REPO" config branch.main.remote origin
git -C "$TAG_REPO" config branch.main.merge refs/heads/main
git -C "$TAG_REPO" update-ref refs/remotes/origin/main HEAD
git -C "$TAG_REPO" tag v1
TAG_SHA=$(git -C "$TAG_REPO" rev-parse HEAD)
for run_branch in v1 main; do
    fresh
    resp 1 '200 OK' '[]'
    resp wfruns '200 OK' "{\"workflow_runs\":[{\"id\":9,\"event\":\"push\",\"head_branch\":\"$run_branch\",\"head_sha\":\"$TAG_SHA\"}]}"
    resp 2 '200 OK' "$RUN_OK"
    gw 10 -C "$TAG_REPO" --workflow release.yml -i 1 -t 1
    check "auto commit: pushed main finds $run_branch run by SHA only" 0 \
        stdout-has=actions/runs/9 "argv-has=head_sha=$TAG_SHA" argv-lacks=branch= calls=6
done

# PR mode still filters other branches, including tags on the same SHA.
fresh
resp 1 '200 OK' "{\"head\":{\"sha\":\"$TAG_SHA\",\"ref\":\"main\",\"repo\":{\"full_name\":\"o/r\"}}}"
resp wfruns '200 OK' '{"workflow_runs":[{"id":11,"event":"push","head_branch":"main"},{"id":12,"event":"push","head_branch":"v1"}]}'
resp 2 '200 OK' "$RUN_OK"
gw 10 pr 7 -R o/r --workflow release.yml -i 1
check "pr workflow: branch filter still excludes a tag on the same SHA" 0 \
    stdout-has=actions/runs/11 argv-has=branch=main argv-lacks=actions/runs/12 calls=5

# R1: a stuck ignored check gets one grace period, not the full timeout.
for shape in only mixed; do
    fresh
    if [ "$shape" = only ]; then
        checks='{"check_runs":[{"id":2,"name":"flaky","status":"in_progress","check_suite":{"id":5}}]}'
        count=1
    else
        checks='{"check_runs":[{"id":1,"name":"build","status":"completed","conclusion":"success","check_suite":{"id":5}},{"id":2,"name":"flaky","status":"in_progress","check_suite":{"id":5}}]}'
        count=2
    fi
    resp checks '200 OK' "$checks"
    resp suites '200 OK' "{\"check_suites\":[{\"id\":5,\"status\":\"in_progress\",\"latest_check_runs_count\":$count}]}"
    started=$SECONDS
    GH_WAIT_GRACE=1 gw 10 commit "$CHECK_SHA" -R o/r --ignore flaky -i 1 -t 2
    check "R1: $shape suite with a stuck ignored check succeeds after grace" 0 stdout-has=ok stderr-lacks=timeout
    [ $((SECONDS - started)) -ge 1 ] || { echo "FAIL R1: grace was skipped ($shape)"; fail=1; }
done

# A newly created check restarts that suite's grace, even if already completed.
fresh
resp 1 '200 OK' '{"check_runs":[{"id":2,"name":"flaky","status":"in_progress","check_suite":{"id":5}}]}'
resp 2 '200 OK' '{"check_suites":[{"id":5,"status":"in_progress","latest_check_runs_count":1}]}'
for n in 1 2 3 4 5 6 7 8 9; do
    resp "$((n * 2 + 1))" '200 OK' '{"check_runs":[{"id":2,"name":"flaky","status":"in_progress","check_suite":{"id":5}},{"id":3,"name":"build","status":"completed","conclusion":"success","check_suite":{"id":5}}]}'
    resp "$((n * 2 + 2))" '200 OK' '{"check_suites":[{"id":5,"status":"in_progress","latest_check_runs_count":2}]}'
done
started=$SECONDS
GH_WAIT_GRACE=2 gw 12 commit "$CHECK_SHA" -R o/r --ignore flaky -i 1 -t 3
check "R1: a new check restarts the suite grace" 0 stdout-has=ok stderr-lacks=timeout
[ $((SECONDS - started)) -ge 3 ] || { echo 'FAIL R1: new check did not restart grace'; fail=1; }

# R2: fork PR runs can have an empty pull_requests array.
R2_REPO=$T/fork-workflow
git -C "$T" init -q -b fix/x "$R2_REPO"
git -C "$R2_REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m fork-workflow
git -C "$R2_REPO" remote add origin https://github.com/forker/r.git
git -C "$R2_REPO" update-ref refs/remotes/origin/fix/x HEAD
git -C "$R2_REPO" config branch.fix/x.remote origin
git -C "$R2_REPO" config branch.fix/x.merge refs/heads/fix/x
R2_SHA=$(git -C "$R2_REPO" rev-parse HEAD)
for mode in pr auto; do
    fresh
    if [ "$mode" = pr ]; then
        args=(pr 7 -R o/r); head_slot=1; run_slot=2; expected_calls=5
    else
        args=(-C "$R2_REPO" -R o/r); head_slot=2; run_slot=3; expected_calls=6
        resp 1 '200 OK' '[{"number":7}]'
    fi
    resp "$head_slot" '200 OK' "{\"head\":{\"sha\":\"$R2_SHA\",\"ref\":\"fix/x\",\"repo\":{\"full_name\":\"forker/r\"}}}"
    resp wfruns '200 OK' '{"workflow_runs":[{"id":800,"event":"pull_request","head_branch":"fix/x","head_repository":{"full_name":"other/r"},"pull_requests":[]},{"id":801,"event":"pull_request","head_branch":"other","head_repository":{"full_name":"forker/r"},"pull_requests":[]},{"id":900,"event":"pull_request","head_branch":"fix/x","head_repository":{"full_name":"forker/r"},"pull_requests":[]}]}'
    resp "$run_slot" '200 OK' "$RUN_OK"
    gw 10 "${args[@]}" --workflow ci.yml -i 1 -t 2
    check "R2: $mode matches empty-list fork PR by repo and ref" 0 stdout-has=actions/runs/900 \
        argv-lacks=actions/runs/800 argv-lacks=actions/runs/801 calls="$expected_calls"
done

# R3: fork-local PRs take precedence, including triangular checkouts.
R3_REPO=$T/fork-local
git -C "$T" init -q -b feature "$R3_REPO"
git -C "$R3_REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m fork-local
git -C "$R3_REPO" remote add origin https://github.com/me/r.git
git -C "$R3_REPO" remote add upstream https://github.com/base/r.git
git -C "$R3_REPO" config branch.feature.merge refs/heads/feature
git -C "$R3_REPO" config branch.feature.pushRemote origin
git -C "$R3_REPO" config push.default current
git -C "$R3_REPO" update-ref refs/remotes/origin/feature HEAD
git -C "$R3_REPO" update-ref refs/remotes/upstream/feature HEAD
R3_SHA=$(git -C "$R3_REPO" rev-parse HEAD)
for tracking in origin upstream; do
    git -C "$R3_REPO" config branch.feature.remote "$tracking"
    fresh
    resp repo '200 OK' '{"parent":{"full_name":"base/r"}}'
    resp prlist.me '200 OK' '[{"number":3}]'
    resp prlist.base '200 OK' '[]'
    resp 1 '200 OK' "{\"head\":{\"sha\":\"$R3_SHA\",\"ref\":\"feature\",\"repo\":{\"full_name\":\"me/r\"}}}"
    resp 2 '200 OK' "$RUNS_OK"
    resp 3 '200 OK' "$SUITES_DONE"
    gw 10 -C "$R3_REPO" -i 1
    check "R3: fork-local PR wins with $tracking tracking" 0 'stderr-has=PR #3' \
        argv-has=repos/me/r/pulls/3 argv-lacks=repos/base/r/pulls \
        'argv-exact-lacks=api -i repos/me/r' calls=4
done

# R4: unrelated hosts and local paths must not turn into GitHub repo names.
R4_REPO=$T/remote-hosts
git -C "$T" init -q -b feature "$R4_REPO"
git -C "$R4_REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m remote-hosts
git -C "$R4_REPO" remote add origin https://github.com/o/r.git
git -C "$R4_REPO" config branch.feature.remote origin
git -C "$R4_REPO" config branch.feature.merge refs/heads/feature
git -C "$R4_REPO" update-ref refs/remotes/origin/feature HEAD
R4_SHA=$(git -C "$R4_REPO" rev-parse HEAD)
for spec in 'git@gitlab.com:Foo/Bar.git|foo/bar' 'https://gitea.example.com/a/b.git|a/b' '/srv/git/repo.git|git/repo' 'git@not-github:o/r.git|o/r'; do
    url=${spec%|*}; pair=${spec##*|}
    git -C "$R4_REPO" remote set-url origin "$url"
    fresh
    echo o/r > "$S/1.out"
    resp 2 '200 OK' '[]'
    resp 3 '200 OK' "$RUNS_OK"
    resp 4 '200 OK' "$SUITES_DONE"
    asserts=('argv-has=repo view' calls=4)
    [ "$pair" = o/r ] || asserts+=("argv-lacks=repos/$pair/")
    gw 10 -C "$R4_REPO" -i 1
    check "R4: auto uses gh repo view for $url" 0 "${asserts[@]}"

    fresh
    resp 1 '200 OK' "{\"head\":{\"sha\":\"old111\",\"ref\":\"feature\",\"repo\":{\"full_name\":\"$pair\"}}}"
    resp 2 '200 OK' "$RUNS_OK"
    resp 3 '200 OK' "$SUITES_DONE"
    gw 10 pr 7 -C "$R4_REPO" -R o/r -i 1
    check "R4: non-GitHub push remote skips PR catch-up ($url)" 0 \
        stdout-lacks=wait:PR argv-has=commits/old111/check-runs calls=3
done

fresh
git -C "$R4_REPO" remote set-url origin git@github-audi:o/r.git
resp 1 '200 OK' '{"head":{"sha":"old111","ref":"feature","repo":{"full_name":"o/r"}}}'
resp 2 '200 OK' "{\"head\":{\"sha\":\"$R4_SHA\",\"ref\":\"feature\",\"repo\":{\"full_name\":\"o/r\"}}}"
resp 3 '200 OK' "$RUNS_OK"
resp 4 '200 OK' "$SUITES_DONE"
gw 10 pr 7 -C "$R4_REPO" -R o/r -i 1
check "R4: GitHub SSH alias uses the configured local resolver" 0 ssh-has=github-audi \
    "argv-has=commits/$R4_SHA/check-runs" calls=4

# G1: JSON bodies must never be external-command arguments.
fresh
large=$(jq -cn '{check_runs:[range(60) as $i | {id:$i,name:"job-\($i)",status:"completed",conclusion:"success",html_url:"https://github.com/o/r/actions/runs/9/job/\($i)",output:{summary:("x" * 40000)}}]}')
resp 2 '200 OK' "$large"
resp 3 '200 OK' '{"check_suites":[{"status":"completed","conclusion":"success","latest_check_runs_count":60}]}'
resp 1 '200 OK' '{"head":{"sha":"abc123","ref":""}}'
gw 10 pr 5 -R o/r -i 1 -t 1 --sha abc123
# PR startup gets its own response before the large checks response.
check "G1: large green PR exits successfully and prints URL" 0 stdout-has=https://github.com/o/r/actions/runs/9 stderr-lacks='Argument list too long' calls=3
unset large

# A jq failure while replacing the kept list must terminate immediately.
JQ_REAL=$(command -v jq)
cat > "$T/bin/jq" <<'EOF'
#!/bin/bash
if [ "${JQ_FAIL_KEEP:-0}" = 1 ]; then
    for arg in "$@"; do
        if [[ $arg == *'.check_runs = $checks'* ]]; then echo 'injected jq failure' >&2; exit 5; fi
    done
fi
exec "$JQ_REAL" "$@"
EOF
chmod +x "$T/bin/jq"
export JQ_REAL
fresh
resp 1 '200 OK' '{"head":{"sha":"abc123","ref":""}}'
resp 2 '200 OK' "$RUNS_OK"
JQ_FAIL_KEEP=1 gw 10 pr 5 -R o/r -i 1 -t 1
check "G1: jq transformation failure exits 2 immediately" 2 'stderr-has=injected jq failure' stderr-lacks=timeout calls=2
rm "$T/bin/jq"

# G2: ignored visible jobs cannot hide jobs that have not been created yet.
fresh
resp 1 '200 OK' '{"check_runs":[{"name":"build","status":"completed","conclusion":"success","check_suite":{"id":5}},{"name":"flaky","status":"in_progress","check_suite":{"id":5}}]}'
resp 2 '200 OK' '{"check_suites":[{"id":5,"status":"in_progress","latest_check_runs_count":2}]}'
resp 3 '200 OK' '{"check_runs":[{"name":"build","status":"completed","conclusion":"success","check_suite":{"id":5}},{"name":"flaky","status":"in_progress","check_suite":{"id":5}},{"name":"deploy","status":"completed","conclusion":"failure","check_suite":{"id":5}}]}'
gw 10 commit "$CHECK_SHA" -R o/r -i 1 --ignore flaky
check "G2: mixed suite waits for a delayed nonignored failure" 1 'stdout-has=workflow still running' stdout-has=fail:deploy calls=3

fresh
resp 1 '200 OK' '{"check_runs":[{"name":"flaky","status":"in_progress","check_suite":{"id":5}}]}'
resp 2 '200 OK' '{"check_suites":[{"id":5,"status":"in_progress","latest_check_runs_count":1},{"id":6,"app":{"name":"GitHub Actions"},"status":"queued","latest_check_runs_count":0}]}'
resp 3 '200 OK' '{"check_runs":[{"name":"flaky","status":"in_progress","check_suite":{"id":5}},{"name":"real-ci","status":"completed","conclusion":"failure","check_suite":{"id":6}}]}'
gw 10 commit "$CHECK_SHA" -R o/r -i 1 --ignore flaky
check "G2: all visible checks ignored still waits for queued Actions" 1 'stdout-has=2 workflow still running' stdout-has=fail:real-ci calls=3

fresh
resp 1 '200 OK' '{"check_runs":[{"name":"flaky","status":"in_progress","check_suite":{"id":5}}]}'
resp 2 '200 OK' '{"check_suites":[{"id":5,"status":"completed","conclusion":"success","latest_check_runs_count":1}]}'
gw 10 commit "$CHECK_SHA" -R o/r -i 1 --ignore flaky
check "G2: completed suite does not wait for an ignored stale check" 0 stdout-has=ok calls=2

# G5: HEAD catch-up compares the repo suffix, not a fixed GitHub host spelling.
U=$T/urls
git -C "$T" init -q -b feat "$U"
git -C "$U" -c user.name=t -c user.email=t@t commit -q --allow-empty -m urls
git -C "$U" remote add origin https://github.com/o/r.git
git -C "$U" update-ref refs/remotes/origin/feat HEAD
git -C "$U" config branch.feat.remote origin
git -C "$U" config branch.feat.merge refs/heads/feat
URL_SHA=$(git -C "$U" rev-parse HEAD)
for url in 'git@github-audi:o/r.git' 'https://user:fake-token@github.com/o/r.git' 'ssh://git@github.com:22/o/r.git' 'https://GitHub.com/O/R.git' 'https://github.com/o/r/' 'git@github.com:o/r'; do
    git -C "$U" remote set-url origin "$url"
    fresh
    resp 1 '200 OK' '{"head":{"sha":"old111","ref":"feat","repo":{"full_name":"o/r"}}}'
    resp 2 '200 OK' "{\"head\":{\"sha\":\"$URL_SHA\",\"ref\":\"feat\",\"repo\":{\"full_name\":\"o/r\"}}}"
    resp 3 '200 OK' "$RUNS_OK"
    resp 4 '200 OK' "$SUITES_DONE"
    gw 10 pr 7 -C "$U" -R o/r -i 1
    check "G5: URL form catches up to pushed HEAD ($url)" 0 'stdout-has=waiting for' "argv-has=commits/$URL_SHA/check-runs" argv-lacks=commits/old111 calls=4
    fresh
    resp 1 '200 OK' '[]'
    resp 2 '200 OK' "$RUNS_OK"
    resp 3 '200 OK' "$SUITES_DONE"
    gw 10 -C "$U" -i 1
    check "G5: auto derives the last two path components ($url)" 0 'argv-has=repos/o/r/pulls?head=o%3Afeat&state=open' calls=4
done

# G3: a triangular checkout's push repo supplies the head owner, not the PR base.
F=$T/fork
git -C "$T" init -q -b feat "$F"
git -C "$F" -c user.name=t -c user.email=t@t commit -q --allow-empty -m fork
git -C "$F" remote add origin https://github.com/fork/project.git
git -C "$F" remote add upstream https://github.com/base/project.git
git -C "$F" config branch.feat.remote upstream
git -C "$F" config branch.feat.merge refs/heads/feat
git -C "$F" config branch.feat.pushRemote origin
git -C "$F" config push.default current
git -C "$F" update-ref refs/remotes/origin/feat HEAD
git -C "$F" update-ref refs/remotes/upstream/feat HEAD
FORK_SHA=$(git -C "$F" rev-parse HEAD)
fresh
resp 1 '200 OK' '[{"number":7}]'
resp 2 '200 OK' "{\"head\":{\"sha\":\"$FORK_SHA\",\"ref\":\"feat\",\"repo\":{\"full_name\":\"fork/project\"}}}"
resp 3 '200 OK' "$RUNS_OK"
resp 4 '200 OK' "$SUITES_DONE"
gw 10 -C "$F" -i 1
check "G3: triangular push finds the PR on upstream" 0 'stderr-has=PR #7' \
    'argv-has=repos/base/project/pulls?head=fork%3Afeat&state=open' argv-has=repos/fork/project/pulls calls=5

fresh
resp 1 '200 OK' '[]'
resp 2 '200 OK' "$RUNS_OK"
resp 3 '200 OK' "$SUITES_DONE"
gw 10 -C "$F" -i 1
check "G3: no upstream PR falls back to the pushed fork commit" 0 'stderr-has=no open PR' \
    "argv-has=repos/fork/project/commits/$FORK_SHA/check-runs" calls=4

# After no fork-local PR, one repo read can discover the fork parent.
git -C "$F" config branch.feat.remote origin
fresh
resp repo '200 OK' '{"parent":{"full_name":"base/project"}}'
resp 1 '200 OK' '[{"number":7}]'
resp 2 '200 OK' "{\"head\":{\"sha\":\"$FORK_SHA\",\"ref\":\"feat\",\"repo\":{\"full_name\":\"fork/project\"}}}"
resp 3 '200 OK' "$RUNS_OK"
resp 4 '200 OK' "$SUITES_DONE"
gw 10 -C "$F" -i 1
check "G3: fork parent lookup stays within three discovery requests" 0 \
    'argv-has=repos/base/project/pulls?head=fork%3Afeat&state=open' calls=6

fresh
resp 1 '200 OK' '[{"number":8}]'
resp 2 '200 OK' "{\"head\":{\"sha\":\"$FORK_SHA\",\"ref\":\"feat\",\"repo\":{\"full_name\":\"fork/project\"}}}"
resp 3 '200 OK' "$RUNS_OK"
resp 4 '200 OK' "$SUITES_DONE"
gw 10 -C "$F" -R explicit/project -i 1
check "G3: explicit repo overrides PR base without metadata lookup" 0 \
    'argv-has=repos/explicit/project/pulls?head=fork%3Afeat&state=open' calls=4

# G6: resolve abbreviated commit targets before checks or workflow listings.
FULL_SHA=1234567890abcdef1234567890abcdef12345678
fresh
resp 1 '200 OK' "{\"sha\":\"$FULL_SHA\"}"
resp 2 '200 OK' '{"workflow_runs":[{"id":7}]}'
resp 3 '200 OK' "$RUN_OK"
resp 4 '200 OK' '{"workflow_runs":[{"id":7}]}'
gw 10 commit 1234567 -R o/r --workflow ci.yml -i 1
check "G6: short commit workflow query uses the full API SHA" 0 \
    "argv-has=head_sha=$FULL_SHA" argv-has='api -i repos/o/r/commits/1234567' calls=5

fresh
resp 1 '200 OK' "{\"sha\":\"$FULL_SHA\"}"
resp 2 '200 OK' "$RUNS_OK"
resp 3 '200 OK' "$SUITES_DONE"
gw 10 commit 1234567 -R o/r -i 1
check "G6: plain commit checks also use the resolved SHA" 0 \
    "argv-has=commits/$FULL_SHA/check-runs" calls=3

fresh
resp 1 '404 Not Found' '{"message":"No commit found"}'
echo 'gh: No commit found (HTTP 404)' > "$S/1.err"
gw 10 commit 1234567 -R o/r -i 1
check "G6: commit resolution failure stops before CI queries" 2 'stderr-has=HTTP 404' argv-lacks=check-runs calls=1

# G7: auto's local HEAD is a bounded guess; explicit --sha is not.
E=$T/etag
git -C "$T" init -q -b feat "$E"
git -C "$E" -c user.name=t -c user.email=t@t commit -q --allow-empty -m etag
git -C "$E" remote add origin https://github.com/o/r.git
git -C "$E" update-ref refs/remotes/origin/feat HEAD
git -C "$E" config branch.feat.remote origin
git -C "$E" config branch.feat.merge refs/heads/feat
fresh
resp 1 '200 OK' '[{"number":7}]'
for n in 2 3 4; do resp "$n" '200 OK' '{"head":{"sha":"newer99","ref":"feat","repo":{"full_name":"o/r"}}}' 'ETag: "head"'; done
resp 5 '200 OK' "$RUNS_OK"
resp 6 '200 OK' "$SUITES_DONE"
GH_WAIT_CATCHUP=2 gw 15 -C "$E" -i 1 -t 5
check "G7: auto follows a newer PR head after bounded catch-up" 0 'stderr-has=PR head stayed newer99' \
    argv-has=commits/newer99/check-runs 'argv-has=If-None-Match: "head"' calls=6

fresh
resp 1 '200 OK' '{"head":{"sha":"old111","ref":"feat"}}' 'ETag: "head"'
resp 2 '304 Not Modified' ''
resp 3 '200 OK' '{"head":{"sha":"abc123def","ref":"feat"}}' 'ETag: "new"'
resp 4 '200 OK' "$RUNS_OK"
resp 5 '200 OK' "$SUITES_DONE"
gw 15 pr 7 -R o/r --sha abc123 -i 1
check "G7: PR head catch-up accepts 304 and sends its ETag" 0 \
    'argv-has=If-None-Match: "head"' stderr-lacks=attempt argv-has=commits/abc123def/check-runs calls=5

# G4: workflow waits cover all matching runs and one post-completion discovery pass.
PAIR='{"workflow_runs":[{"id":111},{"id":222}]}'
fresh
resp 1 '200 OK' "$PAIR" 'ETag: "listing"'
resp 2 '200 OK' "$RUN_OK"
resp 3 '304 Not Modified' ''
resp 4 '200 OK' '{"status":"completed","conclusion":"failure"}'
gw 10 commit "$CHECK_SHA" -R o/r --workflow ci.yml --log-lines 0 -i 1
check "G4: all matching runs participate, cached re-list accepts 304" 1 \
    stdout-has=actions/runs/111 stdout-has=actions/runs/222 'argv-has=If-None-Match: "listing"' \
    argv-has=per_page=100 calls=6

fresh
resp 1 '200 OK' '{"workflow_runs":[{"id":111}]}'
resp 2 '200 OK' "$RUN_OK"
resp 3 '200 OK' "$PAIR"
resp 4 '200 OK' '{"status":"completed","conclusion":"failure"}'
gw 10 commit "$CHECK_SHA" -R o/r --workflow ci.yml --log-lines 0 -i 1
check "G4: re-list after first completion catches a newly created run" 1 stdout-has=actions/runs/222 calls=6

FILTERED='{"workflow_runs":[{"id":333,"event":"push","head_branch":"other"},{"id":444,"event":"pull_request","head_branch":"feat","pull_requests":[{"number":99}]},{"id":111,"event":"push","head_branch":"feat"},{"id":222,"event":"pull_request","head_branch":"feat","pull_requests":[{"number":45}]}]}'
fresh
resp 1 '200 OK' '{"head":{"sha":"abc123","ref":"feat"}}'
resp 2 '200 OK' "$FILTERED"
resp 3 '200 OK' "$RUN_OK"
resp 4 '200 OK' "$FILTERED"
resp 5 '200 OK' '{"status":"completed","conclusion":"failure"}'
gw 10 pr 45 -R o/r --workflow ci.yml --log-lines 0 -i 1
check "G4: PR workflow filters branch and PR while retaining push and PR runs" 1 \
    argv-has=branch=feat argv-lacks=actions/runs/333 argv-lacks=actions/runs/444 stdout-has=actions/runs/222 calls=7

fresh
resp 1 '200 OK' '{"workflow_runs":[{"id":111}]}' 'Link: <https://api.github.com/next>; rel="next"'
resp 2 '200 OK' '{"workflow_runs":[{"id":222}]}'
resp 3 '200 OK' "$RUN_OK"
resp 4 '200 OK' "$PAIR"
resp 5 '200 OK' '{"status":"completed","conclusion":"failure"}'
gw 10 commit "$CHECK_SHA" -R o/r --workflow ci.yml --log-lines 0 -i 1
check "G4: workflow run discovery follows pagination" 1 argv-has=page=2 stdout-has=actions/runs/222 calls=7

fresh
resp 1 '200 OK' '{"workflow_runs":[{"id":111,"run_attempt":1}]}'
resp 2 '200 OK' '{"status":"completed","conclusion":"failure","run_attempt":1}'
resp 3 '200 OK' '{"workflow_runs":[{"id":111,"run_attempt":2}]}'
resp 4 '200 OK' '{"status":"completed","conclusion":"success","run_attempt":2}'
gw 10 commit "$CHECK_SHA" -R o/r --workflow ci.yml --log-lines 0 -i 1
check "G4: re-list follows a newer rerun attempt of the same run" 0 stdout-has=ok calls=6

# G2: a completed suite cannot create more jobs, even with a stale ignored check.
fresh
resp 1 '200 OK' '{"check_runs":[{"name":"flaky","status":"in_progress","check_suite":{"id":5}}]}'
resp 2 '200 OK' '{"check_suites":[{"id":5,"status":"completed","conclusion":"failure","latest_check_runs_count":1}]}'
gw 10 commit "$CHECK_SHA" -R o/r -i 1 -t 1 --ignore flaky
check "G2: completed all-ignored failed suite needs no check catch-up" 0 stdout-has=ok calls=2

# Progress cases.
fresh
resp 1 '200 OK' "$RUN_WAIT" 'ETag: "run1"'
jobs_resp 1 '{"jobs":[{"name":"build","status":"completed","conclusion":"success"},{"name":"test-linux","status":"in_progress"},{"name":"deploy","status":"queued"}]}'
resp 2 '304 Not Modified' ''
resp 3 '200 OK' '{"status":"in_progress","updated_at":"later"}' 'ETag: "run2"'
jobs_resp 2 '{"jobs":[{"name":"build","status":"completed","conclusion":"success"},{"name":"test-linux","status":"completed","conclusion":"success"},{"name":"deploy","status":"in_progress"}]}'
resp 4 '200 OK' "$RUN_OK"
jobs_resp 3 '{"jobs":[{"name":"build","status":"completed","conclusion":"success"},{"name":"test-linux","status":"completed","conclusion":"success"},{"name":"deploy","status":"completed","conclusion":"success"}]}'
gw 20 run 7 -R o/r -i 1
check "progress: changed run fetches jobs, 304 costs no jobs request" 0 \
    'stdout-has=jobs 1/3 done, running: test-linux' 'stdout-has=jobs 2/3 done, running: deploy' \
    'stdout-has=jobs 3/3 done' 'argv-has=If-None-Match: "run1"' calls=7

fresh
resp 1 '200 OK' "$RUN_WAIT"
resp 2 '200 OK' "$RUN_WAIT"
resp 3 '200 OK' "$RUN_OK"
jobs_resp 1 '{"jobs":[{"name":"build","status":"in_progress"}]}'
jobs_resp 2 '{"jobs":[{"name":"build","status":"completed","conclusion":"success"}]}'
gw 20 run 7 -R o/r -i 1
check "progress: identical run bodies do not fetch jobs again" 0 'stdout-has=jobs 1/1 done' calls=5

fresh
resp 1 '200 OK' "$RUN_OK"
echo 'gh: jobs unavailable' > "$S/jobs.1.err"; echo 1 > "$S/jobs.1.rc"
gw 20 run 7 -R o/r -i 1
check "progress: unavailable jobs do not hide a successful run" 0 'stderr-has=jobs unavailable' calls=2

# Failure log cases.
fresh
resp 1 '200 OK' '{"status":"completed","conclusion":"failure"}'
jobs_resp 1 '{"jobs":[{"id":11,"name":"build","status":"completed","conclusion":"failure","html_url":"https://ci.example/job/11"}]}'
printf '2026-11-15T00:00:01.001Z first-dropped\n2026-11-15T00:00:02.001Z second-kept\n2026-11-15T00:00:03.001Z third-kept\n' > "$S/log.11.out"
gw 20 run 7 -R o/r --log-lines 2 -i 1
check "logs: failed job URL and tail without timestamps" 1 stdout-has=build stdout-has=https://ci.example/job/11 \
    stdout-has=second-kept stdout-has=third-kept stdout-lacks=first-dropped stdout-lacks=2026-11-15T \
    argv-has=actions/jobs/11/logs calls=3

fresh
resp 1 '200 OK' '{"status":"completed","conclusion":"failure"}'
jobs_resp 1 '{"jobs":[{"id":11,"name":"build","status":"completed","conclusion":"failure"}]}'
for n in $(seq -w 1 45); do printf 'line-%s\n' "$n"; done > "$S/log.11.out"
gw 20 run 7 -R o/r -i 1
check "logs: default tail is 40 lines" 1 stdout-has=line-06 stdout-has=line-45 stdout-lacks=line-05 calls=3

fresh
resp 1 '200 OK' '{"check_runs":[{"id":11,"name":"build","status":"completed","conclusion":"failure","app":{"slug":"github-actions"},"html_url":"https://ci.example/job/11"},{"id":12,"name":"external","status":"completed","conclusion":"failure","app":{"slug":"other"},"html_url":"https://external.example/check"}]}'
echo 'Actions check log' > "$S/log.11.out"
gw 20 commit "$CHECK_SHA" -R o/r -i 1
check "logs: Actions check ID is a job ID, external checks have no job logs" 1 \
    'stdout-has=Actions check log' stdout-has=https://external.example/check argv-lacks=actions/jobs/12/logs calls=2

fresh
resp 1 '200 OK' '{"status":"completed","conclusion":"failure"}'
jobs_resp 1 '{"jobs":[{"id":11,"name":"build","status":"completed","conclusion":"failure","html_url":"https://ci.example/job/11"}]}'
gw 20 run 7 -R o/r --log-lines 0 -i 1
check "logs: zero disables log fetches but keeps failure and URL" 1 stdout-has=https://ci.example/job/11 argv-lacks=/logs calls=2

fresh
resp 1 '200 OK' '{"status":"completed","conclusion":"failure"}'
jobs_resp 1 '{"jobs":[{"id":11,"name":"one","status":"completed","conclusion":"failure"},{"id":12,"name":"two","status":"completed","conclusion":"timed_out"},{"id":13,"name":"three","status":"completed","conclusion":"cancelled"},{"id":14,"name":"four","status":"completed","conclusion":"failure"}]}'
gw 20 run 7 -R o/r -i 1
check "logs: at most three failed jobs are fetched" 1 argv-has=actions/jobs/13/logs argv-lacks=actions/jobs/14/logs calls=5

fresh
resp 1 '200 OK' '{"status":"completed","conclusion":"failure"}'
jobs_resp 1 '{"jobs":[{"id":11,"name":"build","status":"completed","conclusion":"failure"}]}'
echo 'gh: log not available' > "$S/log.11.err"; echo 1 > "$S/log.11.rc"
gw 20 run 7 -R o/r -i 1
check "logs: fetch error preserves failure exit code without retries" 1 'stderr-has=log not available' calls=3

fresh
gw 10 run 7 -R o/r --log-lines -1
check "usage: negative log tail" 2 stderr-has=gh-wait calls=0
gw 10 run 7 -R o/r --log-lines nope
check "usage: nonnumeric log tail" 2 stderr-has=gh-wait calls=0

# Ignore cases.
fresh
resp 1 '200 OK' '{"check_runs":[{"id":11,"name":"windows-test","status":"in_progress","check_suite":{"id":10},"html_url":"https://github.com/o/r/actions/runs/7/job/11"}]}'
resp 2 '200 OK' '{"check_suites":[{"id":10,"status":"completed","conclusion":"success","latest_check_runs_count":1}]}'
gw 20 commit "$CHECK_SHA" -R o/r --ignore 'windows-*' -i 1
check "ignore: completed suite ignores its running check" 0 'stdout-has=ignored checks: windows-test' stdout-has=https://github.com/o/r/actions/runs/7 calls=2

fresh
resp 1 '200 OK' '{"head":{"sha":"abc123","ref":""}}'
resp 2 '200 OK' '{"check_runs":[{"name":"build","status":"completed","conclusion":"success","check_suite":{"id":10}},{"name":"windows-a1","status":"completed","conclusion":"failure","check_suite":{"id":10}},{"name":"lint-extra","status":"in_progress","check_suite":{"id":10}}]}'
resp 3 '200 OK' '{"check_suites":[{"id":10,"status":"completed","conclusion":"failure","latest_check_runs_count":3}]}'
gw 20 pr 45 -R o/r --ignore 'windows-[ab]?' --ignore 'lint-*' -i 1
check "ignore: repeatable Bash globs exclude failed and running checks in a mixed suite" 0 \
    stdout-has=windows-a1 stdout-has=lint-extra 'stdout-lacks= wait:' argv-lacks=/logs calls=3

fresh
resp 1 '200 OK' '{"check_runs":[{"name":"build","status":"completed","conclusion":"success","check_suite":{"id":10}},{"name":"windows-test","status":"completed","conclusion":"failure","check_suite":{"id":10}}]}'
resp 2 '200 OK' '{"check_suites":[{"id":10,"status":"completed","conclusion":"failure","latest_check_runs_count":2}]}'
gw 20 commit "$CHECK_SHA" -R o/r --ignore windows-test -i 1
check "ignore: ignored failure does not leave its suite permanently failed" 0 stdout-has=ok calls=2

# The existing delayed-job guard still applies to suites without ignored jobs.
fresh
resp 1 '200 OK' '{"check_runs":[{"name":"build","status":"completed","conclusion":"success","check_suite":{"id":20}},{"name":"windows-test","status":"in_progress","check_suite":{"id":10}}]}'
resp 2 '200 OK' '{"check_suites":[{"id":10,"status":"in_progress","latest_check_runs_count":1},{"id":20,"status":"in_progress","latest_check_runs_count":1}]}'
resp 3 '200 OK' '{"check_runs":[{"name":"build","status":"completed","conclusion":"success","check_suite":{"id":20}},{"name":"windows-test","status":"in_progress","check_suite":{"id":10}},{"name":"deploy","status":"completed","conclusion":"success","check_suite":{"id":20}}]}'
resp 4 '200 OK' '{"check_suites":[{"id":10,"status":"completed","conclusion":"success","latest_check_runs_count":1},{"id":20,"status":"completed","conclusion":"success","latest_check_runs_count":2}]}'
gw 20 commit "$CHECK_SHA" -R o/r --ignore 'windows-*' -i 1
check "ignore: unrelated workflow with delayed jobs still waits" 0 'stdout-has=wait:2 workflow still running' calls=4

fresh
resp 1 '200 OK' '{"check_runs":[{"name":"build","status":"completed","conclusion":"success","check_suite":{"id":10}},{"name":"windows-test","status":"completed","conclusion":"failure","check_suite":{"id":10}}]}'
resp 2 '200 OK' '{"check_suites":[{"id":10,"status":"completed","conclusion":"failure","latest_check_runs_count":3}]}'
resp 3 '200 OK' '{"check_runs":[{"name":"build","status":"completed","conclusion":"success","check_suite":{"id":10}},{"name":"windows-test","status":"completed","conclusion":"failure","check_suite":{"id":10}},{"name":"deploy","status":"completed","conclusion":"failure","check_suite":{"id":10}}]}'
gw 20 commit "$CHECK_SHA" -R o/r --ignore 'windows-*' -i 1
check "ignore: stale suite snapshot still reveals a new nonignored failure" 1 stdout-has=fail:deploy calls=3

fresh
resp 1 '200 OK' '{"status":"completed","conclusion":"failure"}'
jobs_resp 1 '{"jobs":[{"id":11,"name":"windows-test","status":"completed","conclusion":"failure"},{"name":"build","status":"completed","conclusion":"success"}]}'
gw 20 run 7 -R o/r --ignore 'windows-*' -i 1
check "ignore: run succeeds when every failed job is ignored" 0 'stdout-has=ignored jobs: windows-test' argv-lacks=/logs calls=2

fresh
resp 1 '200 OK' '{"workflow_runs":[{"id":7}]}'
resp 2 '200 OK' '{"status":"completed","conclusion":"failure"}'
jobs_resp 1 '{"jobs":[{"id":11,"name":"windows-test","status":"completed","conclusion":"failure"},{"id":12,"name":"test-linux","status":"completed","conclusion":"failure","html_url":"https://ci.example/linux"}]}'
echo 'linux failed log' > "$S/log.12.out"
resp 3 '200 OK' '{"workflow_runs":[{"id":7}]}'
gw 20 commit "$CHECK_SHA" -R o/r --workflow ci.yml --ignore 'windows-*' -i 1
check "ignore: workflow still fails and logs nonignored jobs" 1 'stdout-has=linux failed log' \
    stdout-has=https://ci.example/linux argv-has=actions/jobs/12/logs argv-lacks=actions/jobs/11/logs calls=5

fresh
resp 1 '200 OK' '{"status":"completed","conclusion":"failure"}'
echo 'gh: jobs unavailable' > "$S/jobs.1.err"; echo 1 > "$S/jobs.1.rc"
gw 20 run 7 -R o/r --ignore '*' -i 1
check "ignore: unavailable jobs cannot turn a failed run green" 1 'stderr-has=jobs unavailable' calls=2

fresh
resp 1 '200 OK' '{"check_runs":[{"name":"build","status":"completed","conclusion":"failure"}]}'
gw 20 commit "$CHECK_SHA" -R o/r --ignore 'windows-*' -i 1
check "ignore: nonmatching glob leaves the failure" 1 stdout-has=fail:build calls=1

fresh
resp 1 '200 OK' '{"status":"completed","conclusion":"failure"}'
jobs_resp 1 '{"jobs":[{"name":"windows-test","status":"completed","conclusion":"failure"}]}
{"jobs":[{"id":12,"name":"test-linux","status":"completed","conclusion":"failure"}]}'
echo 'later page failure' > "$S/log.12.out"
gw 20 run 7 -R o/r --ignore 'windows-*' -i 1
check "jobs: all pages participate in the failure decision" 1 'stdout-has=later page failure' argv-has=--paginate calls=3

# Workflow names must resolve across all pages, including duplicate names.
fresh
resp 1 '200 OK' '{"workflows":[{"id":1,"name":"Other"}]}' 'Link: <https://api.github.com/next>; rel="next"'
resp 2 '200 OK' '{"workflows":[{"id":99,"name":"Release CI"}]}'
resp 3 '200 OK' '{"workflow_runs":[{"id":7}]}'
resp 4 '200 OK' "$RUN_OK"
resp 5 '200 OK' '{"workflow_runs":[{"id":7}]}'
gw 20 commit "$CHECK_SHA" -R o/r --workflow 'Release CI' -i 1
check "workflow: name on a later page resolves" 0 'argv-has=actions/workflows?per_page=100&page=2' \
    argv-has=actions/workflows/99/runs calls=6

fresh
resp 1 '200 OK' '{"workflows":[{"id":1,"name":"Release CI"}]}' 'Link: <https://api.github.com/next>; rel="next"'
resp 2 '200 OK' '{"workflows":[{"id":99,"name":"Release CI"}]}'
gw 20 commit "$CHECK_SHA" -R o/r --workflow 'Release CI' -i 1
check "workflow: duplicate names across pages require a file name" 2 stderr-has=ambiguous argv-lacks=/runs calls=2

# Auto mode uses a real local checkout, with remote-tracking refs but no network.
A=$T/auto
git -C "$T" init -q -b feat "$A"
git -C "$A" -c user.name=t -c user.email=t@t commit -q --allow-empty -m one
git -C "$A" remote add origin https://github.com/o/r.git
git -C "$A" update-ref refs/remotes/origin/feat HEAD
git -C "$A" config branch.feat.remote origin
git -C "$A" config branch.feat.merge refs/heads/feat
AUTO_SHA=$(git -C "$A" rev-parse HEAD)
fresh
resp 1 '200 OK' '[{"number":45}]'
resp 2 '200 OK' "{\"head\":{\"sha\":\"$AUTO_SHA\",\"ref\":\"feat\",\"repo\":{\"full_name\":\"o/r\"}}}"
resp 3 '200 OK' "$RUNS_OK"
resp 4 '200 OK' "$SUITES_DONE"
cd "$A" || exit 1; gw 20; cd - > /dev/null || exit 1
check "auto: zero arguments selects the pushed branch PR" 0 'stderr-has=PR #45 (head' \
    'argv-has=repos/o/r/pulls?head=o%3Afeat&state=open' argv-has=repos/o/r/pulls/45 calls=4

fresh
resp 1 '200 OK' '[]'
resp 2 '200 OK' "$RUNS_OK"
resp 3 '200 OK' "$SUITES_DONE"
gw 20 -C "$A" -i 1
check "auto: options only, no PR waits for HEAD checks" 0 'stderr-has=no open PR' \
    "argv-has=repos/o/r/commits/$AUTO_SHA/check-runs" calls=4

# -C also scopes the existing explicit PR head inference.
fresh
resp 1 '200 OK' '{"head":{"sha":"old111","ref":"feat","repo":{"full_name":"o/r"}}}'
resp 2 '200 OK' "{\"head\":{\"sha\":\"$AUTO_SHA\",\"ref\":\"feat\",\"repo\":{\"full_name\":\"o/r\"}}}"
resp 3 '200 OK' "$RUNS_OK"
resp 4 '200 OK' "$SUITES_DONE"
gw 20 pr 45 -R o/r -C "$A" -i 1
check "pr -C: catches up to that checkout's pushed HEAD" 0 'stdout-has=wait:PR head is old111' \
    "argv-has=commits/$AUTO_SHA/check-runs" calls=4

# pushRemote beats pushDefault, which beats the branch fetch remote.
git -C "$A" remote add publish git@github.com:fork/project.git
git -C "$A" update-ref refs/remotes/publish/feat HEAD
git -C "$A" config remote.pushDefault origin
git -C "$A" config branch.feat.pushRemote publish
fresh
resp 1 '200 OK' '[]'
resp 2 '200 OK' "$RUNS_OK"
resp 3 '200 OK' "$SUITES_DONE"
gw 20 -C "$A" -R base/project -i 1
check "auto: pushRemote owner and explicit base repo" 0 \
    'argv-has=repos/base/project/pulls?head=fork%3Afeat&state=open' argv-lacks=repo\ view calls=3

git -C "$A" config --unset branch.feat.pushRemote
git -C "$A" config remote.pushDefault publish
fresh
resp 1 '200 OK' '[]'
resp 2 '200 OK' "$RUNS_OK"
resp 3 '200 OK' "$SUITES_DONE"
gw 20 -C "$A" -i 1
check "auto: pushDefault head owner and upstream base repo" 0 \
    'argv-has=repos/o/r/pulls?head=fork%3Afeat&state=open' calls=4
git -C "$A" config --unset remote.pushDefault

# A detached tag checkout needs no PR-discovery request.
git -C "$A" tag v1
git -C "$A" checkout -q --detach v1
fresh
resp 1 '200 OK' "$RUNS_OK"
resp 2 '200 OK' "$SUITES_DONE"
gw 20 -C "$A" -i 1
check "auto: detached tag uses its commit" 0 'stderr-has=detached HEAD' \
    "argv-has=commits/$AUTO_SHA/check-runs" argv-lacks=pulls calls=2

git -C "$A" remote set-url origin local-unrecognized-url
fresh
echo o/r > "$S/1.out"
resp 2 '200 OK' "$RUNS_OK"
resp 3 '200 OK' "$SUITES_DONE"
gw 20 -C "$A" -i 1
check "auto: unknown remote URL falls back to gh repo view" 0 'argv-has=repo view' calls=3
git -C "$A" remote set-url origin https://github.com/o/r.git
git -C "$A" checkout -q feat
git -C "$A" -c user.name=t -c user.email=t@t commit -q --allow-empty -m unpushed
fresh
gw 20 -C "$A" -i 1
check "auto: unpushed HEAD says push first without API calls" 2 'stderr-has=push first' \
    'stderr-has=gh-wait commit' calls=0
git -C "$A" update-ref refs/remotes/origin/feat HEAD
git -C "$A" config --unset branch.feat.merge
fresh
gw 20 -C "$A" -i 1
check "auto: branch with no tracking ref says push first" 2 'stderr-has=push first' calls=0

fresh
resp 1 '401 Unauthorized' '{"message":"Bad credentials"}'
echo 'gh: Bad credentials (HTTP 401)' > "$S/1.err"; echo 1 > "$S/1.rc"
git -C "$A" config branch.feat.merge refs/heads/feat
gw 20 -C "$A" -i 1
check "auto: PR discovery API error is not treated as no PR" 2 'stderr-has=HTTP 401' calls=1

# Workflow discovery keeps its ETag while the just-pushed run does not exist.
fresh
resp 1 '200 OK' '{"workflow_runs":[]}' 'ETag: "listing"'
resp 2 '304 Not Modified' ''
resp 3 '200 OK' '{"workflow_runs":[{"id":77}]}' 'ETag: "found"'
resp 4 '200 OK' '{"status":"completed","conclusion":"success","html_url":"https://github.com/o/r/actions/runs/77"}'
resp 5 '304 Not Modified' ''
gw 20 commit "$CHECK_SHA" -R o/r --workflow ci.yml -i 1
check "workflow: waits for a run to appear with conditional listing" 0 'stdout-has=wait:no runs yet' \
    'argv-has=actions/workflows/ci.yml/runs?head_sha=abc123' 'argv-has=If-None-Match: "listing"' \
    argv-has=actions/runs/77 'stdout-has=https://github.com/o/r/actions/runs/77' argv-lacks=check-runs calls=6

fresh
resp 1 '200 OK' '{"head":{"sha":"old111","ref":"feat"}}'
resp 2 '200 OK' '{"head":{"sha":"abc123","ref":"feat"}}'
resp 3 '200 OK' '{"workflows":[{"id":99,"name":"Release CI"}]}'
resp 4 '200 OK' '{"workflow_runs":[{"id":78,"head_branch":"feat","event":"push"}]}'
resp 5 '200 OK' "$RUN_OK"
resp 6 '200 OK' '{"workflow_runs":[{"id":78,"head_branch":"feat","event":"push"}]}'
gw 20 pr 45 -R o/r --sha abc123 --workflow 'Release CI' -i 1
check "workflow: name resolves once after PR head catches up" 0 'stdout-has=wait:PR head is old111' \
    argv-has=actions/workflows/99/runs?head_sha=abc123 argv-lacks=commits/old111 calls=7

fresh
resp 1 '200 OK' '[]'
resp 2 '200 OK' '{"workflow_runs":[{"id":79,"head_branch":"feat","event":"push"}]}'
resp 3 '200 OK' "$RUN_OK"
resp 4 '200 OK' '{"workflow_runs":[{"id":79,"head_branch":"feat","event":"push"}]}'
gw 20 -C "$A" -R o/r --workflow release.yml -i 1
check "workflow: auto commit uses the pushed SHA" 0 \
    "argv-has=actions/workflows/release.yml/runs?head_sha=$(git -C "$A" rev-parse HEAD)" calls=5

fresh
resp 1 '200 OK' '{"workflows":[]}'
gw 20 commit "$CHECK_SHA" -R o/r --workflow Missing -i 1
check "workflow: unknown name is an error" 2 'stderr-has=workflow' calls=1

fresh
resp 1 '200 OK' '{"workflow_runs":[]}' 'ETag: "listing"'
resp 2 '304 Not Modified' ''
gw 20 commit "$CHECK_SHA" -R o/r --workflow ci.yml -i 1 -t 1
check "workflow: absent run times out" 2 stderr-has=timeout

fresh
resp 1 '200 OK' '{"check_runs":[{"name":"build","status":"completed","conclusion":"failure","html_url":"https://ci.example/failed"}]}'
gw 20 commit "$CHECK_SHA" -R o/r -i 1
check "commit: failure prints its check URL" 1 stdout-has=https://ci.example/failed calls=1

fresh
resp 1 '200 OK' '{"check_runs":[{"name":"build","status":"completed","conclusion":"success","html_url":"https://github.com/o/r/actions/runs/77/job/88"}]}'
resp 2 '200 OK' "$SUITES_DONE"
gw 20 commit "$CHECK_SHA" -R o/r -i 1
check "commit: success prints its run URL" 0 stdout-has=https://github.com/o/r/actions/runs/77 calls=2

fresh
gw 10 run 7 -R o/r --workflow ci.yml
check "usage: workflow only applies to commit/pr/auto" 2 stderr-has=gh-wait calls=0

fresh
resp 1 '200 OK' '{"check_runs":[{"name":"build","status":"completed","conclusion":"failure","html_url":"https://github.com/o/r/actions/runs/77/job/88"}]}'
gw 20 commit "$CHECK_SHA" -R o/r -i 1
check "commit: failed Actions check keeps the job URL" 1 stdout-has=https://github.com/o/r/actions/runs/77/job/88 calls=1

# Existing regression cases.

fresh
resp 1 '200 OK' "$RUN_WAIT" 'Etag: W/"abc"'
resp 2 '304 Not Modified' ''
resp 3 '200' "$RUN_OK" 'Etag: W/"def"'
gw 20 run 7 -R o/r -i 1
check "run: in_progress, 304, success" 0 stdout-has=wait:in_progress stdout-has=ok \
    'argv-has=If-None-Match: W/"abc"' argv-has=repos/o/r/actions/runs/7 calls=5

fresh
resp 1 '200 OK' '{"status":"completed","conclusion":"failure"}'
jobs_resp 1 '{"jobs":[{"name":"build","status":"completed","conclusion":"failure"}]}'
gw 20 run 7 -R o/r -i 1
check "run: failure lists failed jobs" 1 stdout-has=fail:failure 'stdout-has=failed jobs: build (failure)' \
    argv-has=repos/o/r/actions/runs/7/jobs

fresh
resp 1 '200 OK' '{"head":{"sha":"abc123","ref":""}}'
resp 2 '200 OK' '{"total_count":0,"check_runs":[]}' 'ETag: "e1"'
resp 3 '200 OK' '{"check_runs":[{"name":"ci","status":"in_progress","conclusion":null},{"name":"lint","status":"completed","conclusion":"success"}]}' 'ETag: "e2"'
resp 4 '200 OK' '{"check_runs":[{"name":"ci","status":"completed","conclusion":"success"},{"name":"lint","status":"completed","conclusion":"skipped"}]}'
resp 5 '200 OK' "$SUITES_DONE"
gw 20 pr 5 -R o/r -i 1
check "pr: no checks, running, ok" 0 'stdout-has=wait:no checks yet' 'stdout-has=wait:1 running (ci)' stdout-has=ok \
    argv-has=repos/o/r/pulls/5 argv-has=repos/o/r/commits/abc123/check-runs 'argv-has=If-None-Match: "e1"' \
    argv-has=repos/o/r/commits/abc123/check-suites calls=5

fresh
resp 1 '200 OK' '{"head":{"sha":"abc123","ref":""}}'
resp 2 '200 OK' "$RUNS_OK"
resp 3 '200 OK' "$SUITES_DONE"
gw 20 pr 5 -R o/r -i 1
check "pr: the start line names the repo" 0 'stderr-has=gh-wait: PR #5 on o/r (from -R)'
fresh
resp 1 '404 Not Found' '{"message":"Not Found"}'
echo 'gh: Not Found (HTTP 404)' > "$S/1.err"; echo 1 > "$S/1.rc"
gw 20 pr 5 -R o/r -i 1
check "pr: the start line is printed before a failed PR read" 2 'stderr-has=PR #5 on o/r' 'stderr-has=HTTP 404' calls=1

# A job with needs: has no check run until the jobs it needs finish, so every existing run can be
# green while its workflow (check suite) is still in progress.
fresh
resp 1 '200 OK' '{"head":{"sha":"abc123","ref":""}}'
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
resp 1 '200 OK' '{"head":{"sha":"abc123","ref":""}}'
resp 2 '200 OK' "$RUNS_OK" 'ETag: "e1"'
resp 3 '200 OK' "$SUITES_RUNNING"
resp 4 '200 OK' "$RUNS_OK" 'ETag: "e1"'
resp 5 '200 OK' "$SUITES_DONE"
gw 20 pr 5 -R o/r -i 1
check "pr: downgrade to wait clears the ETag" 0 'stdout-has=wait:1 workflow still running' stdout-has=ok \
    argv-lacks=If-None-Match calls=5

fresh
resp 1 '200 OK' '{"head":{"sha":"abc123","ref":""}}'
resp 2 '200 OK' "$RUNS_OK"
resp 3 '200 OK' '{"check_suites":[{"app":{"name":"Some App"},"status":"queued","latest_check_runs_count":0},{"app":{"name":"GitHub Actions"},"status":"completed","conclusion":"success","latest_check_runs_count":1}]}'
gw 20 pr 5 -R o/r -i 1
check "pr: queued suite with no runs is ignored" 0 stdout-has=ok stdout-lacks=wait calls=3

fresh
resp 1 '200 OK' '{"head":{"sha":"abc123","ref":""}}'
resp 2 '200 OK' "$RUNS_OK"
resp 3 '502 Bad Gateway' '{"message":"Server Error"}'
echo 'gh: Server Error (HTTP 502)' > "$S/3.err"; echo 1 > "$S/3.rc"
resp 4 '200 OK' "$RUNS_OK"
resp 5 '200 OK' "$SUITES_DONE"
gw 20 pr 5 -R o/r -i 1
check "pr: check-suites error is not ok, retried" 0 'stderr-has=HTTP 502' stdout-has=ok calls=5

fresh
resp 1 '200 OK' '{"head":{"sha":"abc123","ref":""}}'
resp 2 '200 OK' "$RUNS_OK"
printf 'To get started with GitHub CLI, please run:  gh auth login\n' > "$S/3.err"; echo 4 > "$S/3.rc"
gw 20 pr 5 -R o/r -i 1
check "pr: check-suites not logged in stops" 2 'stderr-has=gh auth login' calls=3

# A downstream job can appear and fail between the check-runs read and the suites read: the suite
# is completed but failed, and the green runs snapshot is stale. Re-read the runs, never report ok.
fresh
resp 1 '200 OK' '{"head":{"sha":"abc123","ref":""}}'
resp 2 '200 OK' "$RUNS_OK"
resp 3 '200 OK' '{"check_suites":[{"app":{"name":"GitHub Actions"},"status":"completed","conclusion":"failure","latest_check_runs_count":2}]}'
resp 4 '200 OK' '{"check_runs":[{"name":"lint","status":"completed","conclusion":"success"},{"name":"e2e","status":"completed","conclusion":"failure"}]}'
gw 20 pr 5 -R o/r -i 1
check "pr: a suite that failed after a green runs read is not ok" 1 'stdout-has=fail:e2e' calls=4

# check-suites failing over and over must hit the same 5-error limit as the main request.
fresh
resp 1 '200 OK' '{"head":{"sha":"abc123","ref":""}}'
for n in 2 4 6 8 10; do
    resp $n '200 OK' "$RUNS_OK"
    resp $((n + 1)) '503 Service Unavailable' '{"message":"Unavailable"}'
    echo 'gh: Unavailable (HTTP 503)' > "$S/$((n + 1)).err"; echo 1 > "$S/$((n + 1)).rc"
done
gw 30 pr 5 -R o/r -i 1
check "pr: check-suites failing 5 times in a row gives up" 2 'stderr-has=HTTP 503' calls=11

fresh
resp 1 '200 OK' '{"head":{"sha":"abc123","ref":""}}'
resp 2 '200 OK' '{"check_runs":[{"name":"ci","status":"completed","conclusion":"success"},{"name":"lint","status":"completed","conclusion":"failure"}]}'
gw 20 pr 5 -R o/r -i 1
check "pr: failure names the check" 1 stdout-has=fail:lint calls=2

# A push without a PR (straight to main): wait for the checks of that commit, appearing or not.
fresh
resp 1 '200 OK' '{"total_count":0,"check_runs":[]}' 'ETag: "e1"'
resp 2 '200 OK' "$RUNS_OK" 'ETag: "e2"'
resp 3 '200 OK' "$SUITES_DONE"
gw 20 commit "$CHECK_SHA" -R o/r -i 1
check "commit: waits for its checks to appear and pass" 0 'stdout-has=wait:no checks yet' stdout-has=ok \
    "argv-has=repos/o/r/commits/$CHECK_SHA/check-runs" argv-lacks=pulls calls=3

# Quota used up when reading the PR head: wait for the reset like every later request.
fresh
resp 1 '403 Forbidden' '{"message":"API rate limit exceeded"}' 'X-Ratelimit-Remaining: 0' "X-Ratelimit-Reset: $(( $(date +%s) + 1 ))"
echo 'gh: API rate limit exceeded (HTTP 403)' > "$S/1.err"; echo 1 > "$S/1.rc"
resp 2 '200 OK' '{"head":{"sha":"abc123","ref":"feat"}}'
resp 3 '200 OK' "$RUNS_OK"
resp 4 '200 OK' "$SUITES_DONE"
gw 20 pr 5 -R o/r -i 1
check "pr: rate limit on the head read waits for the reset" 0 'stderr-has=rate limit' stdout-has=ok \
    argv-has=commits/abc123/check-runs calls=4

# Right after a push GitHub can still report the old head: --sha waits for the PR to reach it.
fresh
resp 1 '200 OK' "{\"head\":{\"sha\":\"old111\",\"ref\":\"feat\",\"repo\":{\"full_name\":\"o/r\"}}}"
resp 2 '200 OK' "{\"head\":{\"sha\":\"abc123\",\"ref\":\"feat\",\"repo\":{\"full_name\":\"o/r\"}}}"
resp 3 '200 OK' "$RUNS_OK"
resp 4 '200 OK' "$SUITES_DONE"
gw 20 pr 5 -R o/r -i 1 --sha abc123
check "pr --sha: waits for the PR head to reach the pushed commit" 0 'stdout-has=wait:PR head is old111' \
    argv-has=repos/o/r/commits/abc123/check-runs argv-lacks=commits/old111 calls=4

fresh
resp 1 '200 OK' "{\"head\":{\"sha\":\"abc123def\",\"ref\":\"feat\",\"repo\":{\"full_name\":\"o/r\"}}}"
resp 2 '200 OK' "$RUNS_OK"
resp 3 '200 OK' "$SUITES_DONE"
gw 20 pr 5 -R o/r -i 1 --sha abc123
check "pr --sha: a short sha matches the head" 0 stdout-lacks=wait:PR calls=3

fresh
resp 1 '200 OK' "{\"head\":{\"sha\":\"old111\",\"ref\":\"feat\",\"repo\":{\"full_name\":\"o/r\"}}}"
gw 20 pr 5 -R o/r -i 1 -t 1 --sha abc123
check "pr --sha: never reached times out" 2 'stderr-has=timeout' 'stderr-has=PR head is old111'

# Without --sha, a checkout on the PR's branch whose HEAD is pushed waits for that HEAD.
R=$T/repo
git init -q -b feat "$R" && git -C "$R" -c user.name=t -c user.email=t@t commit -q --allow-empty -m one
git -C "$R" remote add origin https://github.com/o/r.git
git -C "$R" update-ref refs/remotes/origin/feat HEAD
git -C "$R" config branch.feat.remote origin && git -C "$R" config branch.feat.merge refs/heads/feat
HEAD_SHA=$(git -C "$R" rev-parse HEAD)
fresh
resp 1 '200 OK' "{\"head\":{\"sha\":\"old111\",\"ref\":\"feat\",\"repo\":{\"full_name\":\"o/r\"}}}"
resp 2 '200 OK' "{\"head\":{\"sha\":\"$HEAD_SHA\",\"ref\":\"feat\",\"repo\":{\"full_name\":\"o/r\"}}}"
resp 3 '200 OK' "$RUNS_OK"
resp 4 '200 OK' "$SUITES_DONE"
cd "$R" || exit 1; gw 20 pr 5 -R o/r -i 1; cd - > /dev/null || exit 1
check "pr: on the PR branch, waits for the pushed local HEAD" 0 'stdout-has=wait:PR head is old111' \
    "argv-has=commits/$HEAD_SHA/check-runs" argv-lacks=commits/old111 calls=4

fresh
resp 1 '200 OK' "{\"head\":{\"sha\":\"old111\",\"ref\":\"other\"}}"
resp 2 '200 OK' "$RUNS_OK"
resp 3 '200 OK' "$SUITES_DONE"
cd "$R" || exit 1; gw 20 pr 5 -R o/r -i 1; cd - > /dev/null || exit 1
check "pr: another branch's PR keeps its own head" 0 stdout-lacks=wait:PR argv-has=commits/old111/check-runs calls=3

# A network error while waiting for the head is retried like any other request.
fresh
resp 1 '200 OK' "{\"head\":{\"sha\":\"old111\",\"ref\":\"feat\",\"repo\":{\"full_name\":\"o/r\"}}}"
echo 'error connecting to api.github.com' > "$S/2.err"; echo 1 > "$S/2.rc"
resp 3 '200 OK' "{\"head\":{\"sha\":\"abc123\",\"ref\":\"feat\",\"repo\":{\"full_name\":\"o/r\"}}}"
resp 4 '200 OK' "$RUNS_OK"
resp 5 '200 OK' "$SUITES_DONE"
gw 20 pr 5 -R o/r -i 1 --sha abc123
check "pr --sha: a network error on a head read is retried" 0 'stderr-has=error connecting' \
    argv-has=commits/abc123/check-runs calls=5

fresh
resp 1 '200 OK' '{"head":null}'
gw 10 pr 5 -R o/r -i 1
check "pr: a reply without a head says so" 2 'stderr-has=reading PR 5' argv-lacks=commits/null calls=1

# Same branch name in another repo (a fork PR from main, say): not this checkout's HEAD.
fresh
resp 1 '200 OK' "{\"head\":{\"sha\":\"old111\",\"ref\":\"feat\",\"repo\":{\"full_name\":\"x/other\"}}}"
resp 2 '200 OK' "$RUNS_OK"
resp 3 '200 OK' "$SUITES_DONE"
cd "$R" || exit 1; gw 20 pr 5 -R o/r -i 1; cd - > /dev/null || exit 1
check "pr: a PR from another repo's same-named branch keeps its own head" 0 stdout-lacks=wait:PR \
    argv-has=commits/old111/check-runs calls=3

# The PR can already be past the local HEAD (Update branch, a bot, another machine): the
# guess is wrong, so after a bounded wait it takes the PR's current head instead of timing out.
fresh
resp 1 '200 OK' "{\"head\":{\"sha\":\"newer99\",\"ref\":\"feat\",\"repo\":{\"full_name\":\"o/r\"}}}"
resp 9 '200 OK' "$RUNS_OK"
resp 10 '200 OK' "$SUITES_DONE"
cd "$R" || exit 1; GH_WAIT_CATCHUP=4 gw 30 pr 5 -R o/r -i 1; cd - > /dev/null || exit 1
check "pr: a PR head past the local HEAD is taken after the catch-up wait" 0 'stdout-has=wait:PR head is newer9' \
    'stderr-has=newer9' argv-has=commits/newer99/check-runs stdout-has=ok

# An unpushed HEAD is not what GitHub will test.
git -C "$R" -c user.name=t -c user.email=t@t commit -q --allow-empty -m two
fresh
resp 1 '200 OK' "{\"head\":{\"sha\":\"old111\",\"ref\":\"feat\",\"repo\":{\"full_name\":\"o/r\"}}}"
resp 2 '200 OK' "$RUNS_OK"
resp 3 '200 OK' "$SUITES_DONE"
cd "$R" || exit 1; gw 20 pr 5 -R o/r -i 1; cd - > /dev/null || exit 1
check "pr: an unpushed local HEAD is ignored" 0 stdout-lacks=wait:PR argv-has=commits/old111/check-runs calls=3

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
check "network error: shown, retried" 0 'stderr-has=error connecting to api.github.com' stdout-has=ok calls=3

# FK: a fork checkout whose `gh repo view` default is the upstream (2026-11-17 incident:
# `gh-wait commit <fork sha>` waited 62 min on the upstream, which answers 200 with no check runs).
FK=$T/forkcheckout
git -C "$T" init -q -b develop "$FK"
git -C "$FK" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
git -C "$FK" remote add origin https://github.com/base/project.git
git -C "$FK" remote add fork https://github.com/me/project.git
git -C "$FK" update-ref refs/remotes/origin/main HEAD
git -C "$FK" -c user.name=t -c user.email=t@t commit -q --allow-empty -m forkonly
FK_SHA=$(git -C "$FK" rev-parse HEAD)
git -C "$FK" update-ref refs/remotes/fork/develop HEAD
git -C "$FK" reset -q --hard HEAD~1
fresh
resp 1 '200 OK' "$RUNS_OK"
resp 2 '200 OK' "$SUITES_DONE"
gw 20 commit "$FK_SHA" -C "$FK" -i 1
check "FK: commit without -R picks the remote that has the commit" 0 \
    "argv-has=repos/me/project/commits/$FK_SHA/check-runs" argv-lacks='repo view' \
    'stderr-has=on me/project' calls=2

FK_BASE=$(git -C "$FK" rev-parse refs/remotes/origin/main)
git -C "$FK" update-ref refs/remotes/fork/main "$FK_BASE"
fresh
echo base/project > "$S/1.out"
resp 2 '200 OK' "$RUNS_OK"
resp 3 '200 OK' "$SUITES_DONE"
gw 20 commit "$FK_BASE" -C "$FK" -i 1
check "FK: a commit on several remotes falls back to gh repo view" 0 \
    'argv-has=repo view' "argv-has=repos/base/project/commits/$FK_BASE/check-runs" \
    'stderr-has=on base/project' calls=3

fresh
resp 1 '200 OK' "$RUNS_OK"
resp 2 '200 OK' "$SUITES_DONE"
gw 20 commit "$CHECK_SHA" -R o/r -i 1
check "FK: the start line names the repo" 0 'stderr-has=commit abc1230 on o/r'
check "FK: -R is labelled as the source" 0 'stderr-has=commit abc1230 on o/r (from -R)'

# FK: a commit that no remote-tracking ref contains (the fork's branch was rewritten) falls back to the
# push remote before `gh repo view`, which in a fork checkout is the upstream (2026-11-17: openidea).
PF=$T/pushcheckout
git -C "$T" init -q -b develop "$PF"
git -C "$PF" -c user.name=t -c user.email=t@t commit -q --allow-empty -m lost
PF_SHA=$(git -C "$PF" rev-parse HEAD)
git -C "$PF" remote add origin https://github.com/base/project.git
git -C "$PF" remote add fork https://github.com/me/project.git
git -C "$PF" remote set-url --push origin DISABLED
git -C "$PF" config remote.pushDefault fork
fresh
resp 1 '200 OK' "$RUNS_OK"
resp 2 '200 OK' "$SUITES_DONE"
gw 20 commit "$PF_SHA" -C "$PF" -i 1
check "FK: no remote has the commit, the push remote is used before gh repo view" 0 \
    "argv-has=repos/me/project/commits/$PF_SHA/check-runs" argv-lacks='repo view' \
    'stderr-has=on me/project (from push remote fork)' calls=2

git -C "$PF" config --unset remote.pushDefault
git -C "$PF" config branch.develop.pushRemote fork
fresh
resp 1 '200 OK' "$RUNS_OK"
resp 2 '200 OK' "$SUITES_DONE"
gw 20 commit "$PF_SHA" -C "$PF" -i 1
check "FK: branch pushRemote counts as the push remote" 0 \
    'stderr-has=on me/project (from push remote fork)' argv-lacks='repo view' calls=2

# A detached HEAD has no branch pushRemote, only remote.pushDefault.
git -C "$PF" checkout -q --detach
fresh
echo base/project > "$S/1.out"
resp 2 '200 OK' "$RUNS_OK"
resp 3 '200 OK' "$SUITES_DONE"
gw 20 commit "$PF_SHA" -C "$PF" -i 1
check "FK: detached HEAD ignores the branch settings; no pushDefault goes to gh repo view" 0 \
    'argv-has=repo view' 'stderr-lacks=push remote' 'stderr-has=(from gh repo view)'
git -C "$PF" config remote.pushDefault fork
fresh
resp 1 '200 OK' "$RUNS_OK"
resp 2 '200 OK' "$SUITES_DONE"
gw 20 commit "$PF_SHA" -C "$PF" -i 1
check "FK: detached HEAD uses remote.pushDefault" 0 'stderr-has=on me/project (from push remote fork)' argv-lacks='repo view'
git -C "$PF" checkout -q develop

# A DISABLED or non-GitHub push URL is not a repo: next level, gh repo view, still labelled.
git -C "$PF" remote set-url --push fork DISABLED
fresh
echo base/project > "$S/1.out"
resp 2 '200 OK' "$RUNS_OK"
resp 3 '200 OK' "$SUITES_DONE"
gw 20 commit "$PF_SHA" -C "$PF" -i 1
check "FK: a DISABLED push URL falls back to gh repo view" 0 'argv-has=repo view' \
    'stderr-has=on base/project (from gh repo view)' calls=3
git -C "$PF" remote set-url --push fork https://gitlab.com/me/project.git
fresh
echo base/project > "$S/1.out"
resp 2 '200 OK' "$RUNS_OK"
resp 3 '200 OK' "$SUITES_DONE"
gw 20 commit "$PF_SHA" -C "$PF" -i 1
check "FK: a non-GitHub push URL falls back to gh repo view" 0 'argv-has=repo view' \
    'stderr-has=on base/project (from gh repo view)' calls=3
git -C "$PF" remote set-url --push fork https://github.com/me/project.git

# The remote that has the commit wins over a usable push remote that points at another GitHub repo.
git -C "$FK" remote add other https://github.com/other/x.git
git -C "$FK" config remote.pushDefault other
fresh
resp 1 '200 OK' "$RUNS_OK"
resp 2 '200 OK' "$SUITES_DONE"
gw 20 commit "$FK_SHA" -C "$FK" -i 1
check "FK: the remote that has the commit beats the push remote" 0 'stderr-has=on me/project (from remote fork)' \
    stderr-lacks=other/x argv-lacks=repos/other/x argv-lacks='repo view' calls=2
git -C "$FK" config --unset remote.pushDefault
git -C "$FK" remote remove other

# The start line names the repo before the first API call: a failed lookup must still show it.
fresh
resp 1 '422 Unprocessable Entity' '{"message":"No commit found for SHA: abc12"}'
echo 'gh: No commit found (HTTP 422)' > "$S/1.err"; echo 1 > "$S/1.rc"
gw 20 commit abc12 -R o/r -i 1
check "FK: a failed commit lookup still printed the repo" 2 'stderr-has=commit abc12 on o/r' 'stderr-has=HTTP 422' calls=1
fresh
resp 1 '422 Unprocessable Entity' '{"message":"No commit found for SHA: v9"}'
echo 'gh: No commit found (HTTP 422)' > "$S/1.err"; echo 1 > "$S/1.rc"
gw 20 tag v9 -R o/r --workflow release.yml -i 1
check "FK: a failed tag lookup still printed the repo" 2 'stderr-has=tag v9 on o/r' 'stderr-has=HTTP 422' calls=1
fresh
resp 1 '422 Unprocessable Entity' '{"message":"No commit found for SHA: abc12"}'
echo 'gh: No commit found (HTTP 422)' > "$S/1.err"; echo 1 > "$S/1.rc"
gw 20 commit abc12 -C "$PF" -i 1
check "FK: the push remote repo is printed before a failed lookup" 2 \
    'stderr-has=on me/project (from push remote fork)' 'stderr-has=HTTP 422' calls=1

# NC: no check runs and no Actions suite for GH_WAIT_NOCHECKS minutes is a wrong repo, not a slow CI.
THIRD_PARTY='{"check_suites":[{"app":{"slug":"vercel","name":"Vercel"},"status":"queued","latest_check_runs_count":0}]}'
SUITES_QUEUED='{"check_suites":[{"app":{"slug":"github-actions","name":"GitHub Actions"},"status":"queued","latest_check_runs_count":0}]}'
fresh
resp 1 '200 OK' '{"check_runs":[]}'
resp 2 '200 OK' "$THIRD_PARTY"
GH_WAIT_NOCHECKS=0 gw 20 commit "$CHECK_SHA" -R o/r -i 1
check "NC: no checks and no Actions suite stops with a hint" 2 \
    'stderr-has=no checks on o/r' 'stderr-has=-R owner/repo' calls=2

fresh
resp 1 '200 OK' '{"check_runs":[]}'
resp 2 '200 OK' "$SUITES_QUEUED"
resp 3 '200 OK' "$RUNS_OK"
resp 4 '200 OK' "$SUITES_DONE"
GH_WAIT_NOCHECKS=0 gw 20 commit "$CHECK_SHA" -R o/r -i 1
check "NC: a queued Actions suite keeps waiting" 0 stdout-has=ok calls=4

# A completed Actions suite with no check runs is not pending: it must not reset the clock forever.
SUITES_COMPLETED_EMPTY='{"check_suites":[{"app":{"slug":"github-actions","name":"GitHub Actions"},"status":"completed","conclusion":"success","latest_check_runs_count":0}]}'
fresh
resp 1 '200 OK' '{"check_runs":[]}'
resp 2 '200 OK' "$SUITES_COMPLETED_EMPTY"
GH_WAIT_NOCHECKS=0 gw 8 commit "$CHECK_SHA" -R o/r -i 1
check "NC: a completed Actions suite with no runs is not pending" 2 'stderr-has=no checks on o/r' calls=2

fresh
resp 1 '200 OK' '{"workflow_runs":[]}'
GH_WAIT_NOCHECKS=0 gw 20 commit "$CHECK_SHA" -R o/r --workflow ci.yml -i 1
check "NC: no workflow runs either stops with a hint" 2 'stderr-has=no runs of ci.yml on o/r' calls=1

# TG: a tag's workflow wait follows only the tag's runs (the same commit's branch push ran it too).
TAGRUNS='{"workflow_runs":[{"id":111,"event":"push","head_branch":"develop"},{"id":222,"event":"push","head_branch":"v1.2.3"}]}'
fresh
resp 1 '200 OK' "{\"sha\":\"$FULL_SHA\"}"
resp 2 '200 OK' "$TAGRUNS"
resp 3 '200 OK' "$RUN_OK"
resp 4 '200 OK' "$TAGRUNS"
gw 20 tag v1.2.3 -R o/r --workflow release.yml -i 1
check "TG: tag mode follows the tag's run only" 0 stdout-has=actions/runs/222 stdout-lacks=actions/runs/111 \
    'argv-has=repos/o/r/commits/v1.2.3' 'argv-has=branch=v1.2.3' "argv-has=head_sha=$FULL_SHA"

# Without --workflow a tag would return as soon as the branch push of the same commit is green.
fresh
resp 1 '200 OK' "{\"sha\":\"$FULL_SHA\"}"
resp 2 '200 OK' "$RUNS_OK"
resp 3 '200 OK' "$SUITES_DONE"
gw 20 tag v1.2.3 -R o/r -i 1
check "TG: tag without --workflow is a usage error" 2 'stderr-has=--workflow' 'stderr-has=tag' calls=0

# HP: an unpushed HEAD names what to run for something pushed by refspec or tag.
git -C "$A" -c user.name=t -c user.email=t@t commit -q --allow-empty -m unpushed-again
fresh
gw 20 -C "$A" --workflow release.yml -i 1
check "HP: unpushed HEAD hint names commit/tag/run with the repo" 2 'stderr-has=push first' \
    'stderr-has=gh-wait commit <sha> -R o/r --workflow release.yml' 'stderr-has=gh-wait tag <tag> -R o/r' \
    'stderr-has=gh-wait run <run-id> -R o/r' calls=0

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
[ -s "$S/argv" ] && { echo "FAIL no jq: gh was called"; fail=1; }

fresh
gw 10 run 7 -R o/r -i 0
check "usage: -i 0" 2 stderr-has=gh-wait
gw 10 run 7 -R
check "usage: -R without value" 2 stderr-has=gh-wait
gw 10 job 7 -R o/r
check "usage: unknown kind" 2 stderr-has=gh-wait
gw 10 run 7 -R o/r --sha abc
check "usage: --sha is only for pr" 2 stderr-has=gh-wait
exit $fail
