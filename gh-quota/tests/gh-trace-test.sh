#!/usr/bin/env bash
# Tests for bin/gh-trace and bin/gh-trace-shim.sh against fake `gh` and fake `brew` in a temp dir.
# Prints only "ok   ..." lines on success; exits non-zero on failure.

BIN_DIR=$(cd "$(dirname "$0")/../bin" && pwd)
GT=$BIN_DIR/gh-trace
SHIM_TPL=$BIN_DIR/gh-trace-shim.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
unset BASH_ENV
exec </dev/null

REAL_HOME=$HOME
REAL_LOG="$REAL_HOME/.local/state/gh-quota/gh-trace.log"
real_lines_before=0
[ -f "$REAL_LOG" ] && real_lines_before=$(wc -l < "$REAL_LOG" | tr -d ' ')

mkdir -p "$T/home" "$T/sysbin" "$T/stubs" "$T/bin" "$T/real" "$T/rec" "$T/evilbin"
for tool in sh bash cat cp mv ln rm mkdir rmdir chmod stat date ps sed awk tr cut grep \
            sort uniq head tail wc sleep python3 perl uname id readlink dirname \
            basename mktemp env kill pgrep cmp dd ls hostname; do
    tp=$(type -P "$tool" 2>/dev/null || true)
    [ -n "$tp" ] && [ -x "$tp" ] && ln -sf "$tp" "$T/sysbin/$tool"
done
PY3=''
[ -x "$T/sysbin/python3" ] && PY3="$T/sysbin/python3"

export HOME="$T/home"
export GH_TRACE_LOG="$T/default-trace.log"
export PATH="$T/stubs:$T/bin:$T/sysbin"

for cmd in gh brew; do
    resolved=$(command -v "$cmd" 2>/dev/null || true)
    case $resolved in
        ""|"$T"/*) ;;
        *)
            printf 'FAIL hermetic PATH guard: %s resolved outside temp dir: %s\n' "$cmd" "$resolved"
            exit 1 ;;
    esac
done

fail=0
REC=$T/rec

pass() { printf 'ok   %s\n' "$1"; }
nope() { printf 'FAIL %s: %s\n' "$1" "$2"; fail=1; }

make_fake_gh() {
    local dst=$1 ver=${2:-2.65.0}
    mkdir -p "$(dirname "$dst")"
    cat > "$dst" <<EOF
#!/bin/sh
if [ "\${1:-}" = "--version" ]; then
    printf 'gh version %s (fake)\n' '$ver'
    exit 0
fi
if [ "\${1:-}" = "--sleepwrite" ]; then
    sleep 2
    printf 'survived\n' > "\${2:?}"
    exit 0
fi
if [ "\${1:-}" = "--exit" ]; then
    exit "\${2:-0}"
fi
if [ -n "\${REC:-}" ]; then
    printf '%s\n' "\$@" > "\$REC/argv"
    printf '%s\n' "\${GH_PATH:-}" > "\$REC/gh_path"
    printf '%s\n' "\$PATH" > "\$REC/path"
    cat > "\$REC/stdin"
    [ -e "\$REC/out" ] && cat "\$REC/out"
    [ -e "\$REC/err" ] && cat "\$REC/err" >&2
    rc=0
    [ -e "\$REC/rc" ] && rc=\$(cat "\$REC/rc")
    exit "\$rc"
fi
EOF
    chmod +x "$dst"
}

make_fake_gh "$T/real/gh" "2.65.0"
ln -s "$T/real/gh" "$T/bin/gh"

# Fake brew stub controlled by FAKE_BREW_PREFIX and BREW_FAIL_LINK.
cat > "$T/stubs/brew" <<'EOF'
#!/usr/bin/env bash
[ -n "${FAKE_BREW_PREFIX:-}" ] || exit 1
[ -n "${BREW_ARGV_LOG:-}" ] && printf '%s\n' "$*" >> "$BREW_ARGV_LOG"
case "$*" in
    --prefix)
        printf '%s\n' "$FAKE_BREW_PREFIX"
        ;;
    "--prefix gh")
        [ -d "$FAKE_BREW_PREFIX/opt/gh" ] || exit 1
        printf '%s/opt/gh\n' "$FAKE_BREW_PREFIX"
        ;;
    "unlink gh")
        rm -f "$FAKE_BREW_PREFIX/bin/gh"
        ;;
    "link gh")
        [ -z "${BREW_FAIL_LINK:-}" ] || exit 1
        cur=$(readlink "$FAKE_BREW_PREFIX/opt/gh")
        ver=${cur##*/}
        ln -sf "../Cellar/gh/$ver/bin/gh" "$FAKE_BREW_PREFIX/bin/gh"
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod +x "$T/stubs/brew"

reset_rec() {
    rm -rf "$REC"
    mkdir -p "$REC"
}

# 1. usage / help mentions logging-only, who/what/when (not duration), uninstall, brew upgrades
out=$("$GT" --help 2>&1); rc=$?
if [ "$rc" -eq 0 ] \
    && grep -qi 'only logs' <<<"$out" \
    && grep -qi 'never blocks' <<<"$out" \
    && grep -qi 'not duration' <<<"$out" \
    && grep -q 'gh-trace uninstall' <<<"$out" \
    && grep -qi 'upgrading gh underneath' <<<"$out"; then
    pass "usage describes logging-only, who/what/when, uninstall, brew upgrades"
else
    nope "usage describes logging-only, who/what/when, uninstall, brew upgrades" "rc=$rc out=$out"
fi

# === Non-Homebrew (gh.real) tests ===

# 2. install into temp bin/gh symlink (non-brew)
out=$("$GT" install "$T/bin/gh" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ -f "$T/bin/gh" ] && [ ! -L "$T/bin/gh" ] \
    && [ -L "$T/bin/gh.real" ] && [ "$(readlink "$T/bin/gh.real")" = "$T/real/gh" ] \
    && head -n 1 "$T/bin/gh" | grep -q '^#!/bin/sh$' \
    && grep -q 'Moving ' <<<"$out" \
    && grep -q 'Verified: gh version 2.65.0' <<<"$out"; then
    pass "non-brew install moves symlink to gh.real, installs POSIX /bin/sh shim, verifies"
else
    nope "non-brew install moves symlink to gh.real, installs POSIX /bin/sh shim, verifies" "rc=$rc out=$out"
fi

# 3. install idempotent
out=$("$GT" install "$T/bin/gh" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && grep -qi 'already installed' <<<"$out" \
    && [ -L "$T/bin/gh.real" ] && [ "$(readlink "$T/bin/gh.real")" = "$T/real/gh" ]; then
    pass "install is idempotent"
else
    nope "install is idempotent" "rc=$rc out=$out"
fi

# 4. argv, stdout, stderr, GH_PATH passthrough
reset_rec
printf 'hello stdout\n' > "$REC/out"
printf 'hello stderr\n' > "$REC/err"
LOG=$T/logs_perm/trace.log
out=$(REC=$REC GH_TRACE_LOG=$LOG "$T/bin/gh" api -f 'body=hello "world" '\''single'\''' 'spaced arg' -- -n 2>"$T/stderr"); rc=$?
err=$(cat "$T/stderr")
want_argv=$(printf '%s\n' 'api' '-f' 'body=hello "world" '\''single'\''' 'spaced arg' '--' '-n')
got_argv=$(cat "$REC/argv")
got_gh_path=$(cat "$REC/gh_path")
if [ "$rc" -eq 0 ] && [ "$got_argv" = "$want_argv" ] \
    && [ "$out" = "hello stdout" ] && [ "$err" = "hello stderr" ] \
    && [ "$got_gh_path" = "$T/bin/gh" ]; then
    pass "argv, stdout, stderr, GH_PATH passthrough"
else
    nope "argv, stdout, stderr, GH_PATH passthrough" "rc=$rc out=[$out] err=[$err] gh_path=[$got_gh_path]"
fi

# 5. log dir mode 700, log file mode 600, and 8 valid tab-separated fields (with - placeholders)
perm_oct() {
    case $(uname -s) in
        Darwin) stat -f %Lp "$1" ;;
        *)      stat -c %a "$1" ;;
    esac
}
dir_perm=$(perm_oct "$T/logs_perm")
file_perm=$(perm_oct "$LOG")
nlines=$(wc -l < "$LOG" | tr -d ' ')
if [ "$nlines" -eq 1 ] && [ "$dir_perm" = "700" ] && [ "$file_perm" = "600" ]; then
    IFS=$'\t' read -r f_ts f_host f_pid f_dur f_rc f_cwd f_chain f_argv < "$LOG"
    if [[ $f_ts =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{4}$ ]] \
        && [ -n "$f_host" ] \
        && [[ $f_pid =~ ^[0-9]+$ ]] \
        && [ "$f_dur" = "-" ] \
        && [ "$f_rc" = "-" ] \
        && [ "$f_cwd" = "$PWD" ] \
        && [ -n "$f_chain" ] \
        && [[ $f_argv == gh\ api* ]]; then
        pass "log dir 700, file 600, 8 tab-separated fields with - placeholders"
    else
        nope "log dir 700, file 600, 8 tab-separated fields with - placeholders" "ts=$f_ts dur=$f_dur rc=$f_rc chain=$f_chain argv=$f_argv"
    fi
else
    nope "log dir 700, file 600, 8 tab-separated fields with - placeholders" "nlines=$nlines dir=$dir_perm file=$file_perm"
fi

# 6. stdin passthrough
reset_rec
want_stdin=$(printf 'line 1\nline "2" with spaces\n')
printf '%s\n' "$want_stdin" | REC=$REC GH_TRACE_LOG=$LOG "$T/bin/gh" gist create - >/dev/null
got_stdin=$(cat "$REC/stdin")
if [ "$got_stdin" = "$want_stdin" ]; then
    pass "stdin passthrough"
else
    nope "stdin passthrough" "got=[$got_stdin] want=[$want_stdin]"
fi

# 7. exit codes 0, 1, 130, 143 seen unchanged by Python subprocess caller
if [ -n "$PY3" ]; then
    py_rcs=$(GH_TRACE_LOG=$LOG "$PY3" -c '
import subprocess, sys
out = []
for c in ("0", "1", "130", "143"):
    p = subprocess.run([sys.argv[1], "--exit", c], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    out.append(str(p.returncode))
print(",".join(out))
' "$T/bin/gh")
    if [ "$py_rcs" = "0,1,130,143" ]; then
        pass "exit codes 0, 1, 130, 143 pass through unchanged to Python subprocess"
    else
        nope "exit codes 0, 1, 130, 143 pass through unchanged to Python subprocess" "got=$py_rcs"
    fi
else
    pass "exit codes 0, 1, 130, 143 pass through unchanged to Python subprocess (python3 absent, skipped)"
fi

# 8. SIGTERM to shim pid kills real gh directly (no orphan) and still logs the call
KLOG=$T/logs_perm/kill.log
rm -f "$KLOG" "$T/orphan_survived"
GH_TRACE_LOG=$KLOG "$T/bin/gh" --sleepwrite "$T/orphan_survived" >/dev/null 2>&1 &
shim_pid=$!
sleep 0.2
kill -TERM "$shim_pid" 2>/dev/null || true
wait "$shim_pid" 2>/dev/null; kill_rc=$?
sleep 2.2
if [ ! -e "$T/orphan_survived" ] && [ -s "$KLOG" ] && grep -q 'gh --sleepwrite' "$KLOG"; then
    pass "SIGTERM kills execed real gh with no orphan and logs invocation (rc=$kill_rc)"
else
    nope "SIGTERM kills execed real gh with no orphan and logs invocation" "survived=$([ -e "$T/orphan_survived" ] && echo yes || echo no) klog=$(cat "$KLOG" 2>/dev/null)"
fi

# 9. BASH_ENV has no effect on /bin/sh shim
reset_rec
printf 'echo BASH_ENV-NOISE\nexport PATH="%s:%s"\nexport GH_TRACE_REAL="%s"\n' \
    "$T/evilbin" "\$PATH" "$T/real/broken_evil" > "$T/benv.sh"
printf 'ok-clean\n' > "$REC/out"
out=$(BASH_ENV="$T/benv.sh" REC=$REC GH_TRACE_LOG=$LOG "$T/bin/gh" status 2>&1); rc=$?
got_path=$(cat "$REC/path")
if [ "$rc" -eq 0 ] && [ "$out" = "ok-clean" ] && ! grep -q 'evilbin' <<<"$got_path"; then
    pass "BASH_ENV does not inject stdout noise, PATH, or GH_TRACE_REAL"
else
    nope "BASH_ENV does not inject stdout noise, PATH, or GH_TRACE_REAL" "rc=$rc out=[$out] path=[$got_path]"
fi

# 10. T1 token & secret redaction in argv and caller chain
reset_rec
RLOG=$T/logs_perm/redact.log
rm -f "$RLOG"
# 10a: gh secret set and gh variable set keep only subcommand + name
REC=$REC GH_TRACE_LOG=$RLOG "$T/bin/gh" secret set MY_SECRET --body s3cr3tVALUE >/dev/null
REC=$REC GH_TRACE_LOG=$RLOG "$T/bin/gh" variable set MY_VAR -b varSecretVal >/dev/null
# 10b: --body / -b redacted while --body-file keeps path; -f/-F/--field/--raw-field sensitive keys redacted
REC=$REC GH_TRACE_LOG=$RLOG "$T/bin/gh" issue create -b "top secret body" --body-file /tmp/body.md >/dev/null
REC=$REC GH_TRACE_LOG=$RLOG "$T/bin/gh" api -f password=hunter2 -F api_token=tokval1 --field=ClientSecret=sec1 --raw-field access_key=key1 -f title=safe_title /x >/dev/null
# 10c: gh[pousr]_*, github_pat_*, Authorization, GH_TOKEN/GITHUB_TOKEN in argv + caller chain
REC=$REC GH_TRACE_LOG=$RLOG bash -c \
    '"$1" api -H "Authorization: Bearer secret_bearer_999" -H "X-Foo: ghs_HmacTok111" -F a=ghp_Pat111 -F b=gho_Oauth222 -F c=ghu_User333 -F d=ghr_Ref444 -F e=github_pat_11AA_22BB -f GH_TOKEN=env333 -f GITHUB_TOKEN=env444 repos/o/r' \
    _ "$T/bin/gh" >/dev/null 2>&1 -- GH_TOKEN=chain_env_555 ghs_ParentSecret666 password=parentpw777

rdata=$(cat "$RLOG")
bad=0
for leak in s3cr3tVALUE varSecretVal "top secret body" hunter2 tokval1 sec1 key1 secret_bearer_999 ghs_HmacTok111 ghp_Pat111 gho_Oauth222 ghu_User333 ghr_Ref444 11AA_22BB env333 env444 chain_env_555 ParentSecret666 parentpw777; do
    if grep -qF "$leak" <<<"$rdata"; then
        nope "T1 redaction" "leaked [$leak]"
        bad=1
        break
    fi
done
if [ "$bad" -eq 0 ]; then
    if grep -qxF $'gh secret set MY_SECRET' <(awk -F '\t' '{print $8}' "$RLOG") \
        && grep -qxF $'gh variable set MY_VAR' <(awk -F '\t' '{print $8}' "$RLOG") \
        && grep -qF -- '--body-file /tmp/body.md' <<<"$rdata" \
        && grep -qF -- '-f title=safe_title' <<<"$rdata" \
        && grep -qF 'repos/o/r' <<<"$rdata"; then
        pass "T1 redaction: tokens, --body/-b, sensitive fields, secret/variable set, caller chain"
    else
        nope "T1 redaction" "missing expected preserved fields in [$rdata]"
    fi
fi

# 10d: F1 caller chain keeps only first 2 words per ancestor (no sh -c secret body leakage)
F1LOG=$T/logs_perm/f1.log
rm -f "$F1LOG"
REC=$REC GH_TRACE_LOG=$F1LOG sh -c '"$1" secret set FOO --body hunter2supersecret; true' _ "$T/bin/gh" >/dev/null 2>&1
f1_chain=$(awk -F '\t' '{print $7}' "$F1LOG")
if f1_over2=$(awk -F '\t' '{
    n = split($7, a, / < /)
    for (i = 1; i <= n; i++) {
        nw = split(a[i], w, /[[:space:]]+/)
        if (nw > 2) { print a[i]; exit 1 }
    }
}' "$F1LOG") \
    && ! grep -qF 'hunter2supersecret' <<<"$f1_chain" \
    && ! grep -qF -- '--body' <<<"$f1_chain" \
    && grep -qF 'sh -c' <<<"$f1_chain"; then
    pass "F1 caller chain keeps at most 2 words per ancestor (no sh -c secret leak)"
else
    nope "F1 caller chain keeps at most 2 words per ancestor (no sh -c secret leak)" "over2=[$f1_over2] chain=[$f1_chain]"
fi

# 11. missing / unwritable log dir does not break gh
reset_rec
printf 'ok-output\n' > "$REC/out"
out=$(REC=$REC GH_TRACE_LOG=$T/newdir/sub/trace.log "$T/bin/gh" status 2>"$T/stderr"); rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "ok-output" ] && [ -z "$(cat "$T/stderr")" ] && [ -s "$T/newdir/sub/trace.log" ]; then
    pass "missing log dir created cleanly"
else
    nope "missing log dir created cleanly" "rc=$rc out=$out err=$(cat "$T/stderr")"
fi
: > "$T/not_a_dir"
out=$(REC=$REC GH_TRACE_LOG=$T/not_a_dir/sub/trace.log "$T/bin/gh" status 2>"$T/stderr"); rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "ok-output" ] && [ -z "$(cat "$T/stderr")" ]; then
    pass "unwritable log dir does not break gh"
else
    nope "unwritable log dir does not break gh" "rc=$rc out=$out err=$(cat "$T/stderr")"
fi

# 12. T6 rotation lock under concurrency + stale lock recovery
reset_rec
ROTLOG=$T/logs_perm/rot.log
rm -f "$ROTLOG" "${ROTLOG}.1"
rmdir "${ROTLOG}.lock" 2>/dev/null || true
# Pre-fill 10 lines (~3600 bytes) > 3000 so concurrent calls all attempt rotation once.
for i in 1 2 3 4 5 6 7 8 9 10; do
    printf '%0350d\n' "$i" >> "$ROTLOG"
done
pids=()
for i in 1 2 3 4 5 6; do
    REC=$REC GH_TRACE_LOG=$ROTLOG GH_TRACE_MAX_BYTES=3000 "$T/bin/gh" api "r/$i" >/dev/null 2>&1 &
    pids+=("$!")
done
for p in "${pids[@]}"; do wait "$p"; done
c_cur=$(wc -l < "$ROTLOG" | tr -d ' ')
c_rot=0
[ -f "${ROTLOG}.1" ] && c_rot=$(wc -l < "${ROTLOG}.1" | tr -d ' ')
if [ -f "${ROTLOG}.1" ] && [ ! -d "${ROTLOG}.lock" ] && [ $((c_cur + c_rot)) -eq 16 ]; then
    pass "T6 concurrent rotation preserves all lines via mkdir lock ($c_rot + $c_cur = 16)"
else
    nope "T6 concurrent rotation preserves all lines via mkdir lock" "rot=$c_rot cur=$c_cur lock=$([ -d "${ROTLOG}.lock" ] && echo stuck || echo clean)"
fi

# 12b: stale lock cleanup is non-blocking, next call rotates cleanly
: > "$ROTLOG"
for i in 1 2 3 4 5 6 7 8 9 10; do
    printf '%0350d\n' "$i" >> "$ROTLOG"
done
mkdir "${ROTLOG}.lock"
REC=$REC GH_TRACE_LOG=$ROTLOG GH_TRACE_MAX_BYTES=3000 GH_TRACE_LOCK_TIMEOUT=0 "$T/bin/gh" api stale_ok >/dev/null 2>&1; rc=$?
REC=$REC GH_TRACE_LOG=$ROTLOG GH_TRACE_MAX_BYTES=3000 "$T/bin/gh" api after_stale >/dev/null 2>&1; rc2=$?
if [ "$rc" -eq 0 ] && [ "$rc2" -eq 0 ] && [ ! -d "${ROTLOG}.lock" ] && [ -f "${ROTLOG}.1" ] \
    && grep -q 'stale_ok' "${ROTLOG}.1" && grep -q 'after_stale' "$ROTLOG"; then
    pass "T6 stale lock is cleaned up and next call rotates cleanly"
else
    nope "T6 stale lock is cleaned up and next call rotates cleanly" "rc=$rc rc2=$rc2 lock=$([ -d "${ROTLOG}.lock" ] && echo stuck || echo clean)"
fi

# 12c: F3 non-blocking lock & read-only / unremovable stale lock tests (< 0.5s, no orphans)
run_timed_under_half_sec() {
    if [ -n "$PY3" ]; then
        "$PY3" -c '
import subprocess, sys, time
t0 = time.monotonic()
try:
    p = subprocess.run(sys.argv[1:], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=1.5)
    dt = time.monotonic() - t0
    sys.stdout.write(p.stdout.decode(errors="replace"))
    sys.stderr.write(f"elapsed={dt:.3f}\n")
    sys.exit(0 if (p.returncode == 0 and dt < 0.5) else 1)
except subprocess.TimeoutExpired:
    sys.stderr.write("elapsed=TIMEOUT\n")
    sys.exit(2)
' "$@"
    else
        "$@"
    fi
}

# F3a: fresh leftover lock + log over limit completes < 0.5s and logs
reset_rec
printf 'f3a-ok\n' > "$REC/out"
F3A=$T/logs_perm/f3a.log
printf '%0350d\n' 1 > "$F3A"
mkdir "${F3A}.lock"
out=$(REC=$REC GH_TRACE_LOG=$F3A GH_TRACE_MAX_BYTES=100 GH_TRACE_LOCK_TIMEOUT=60 \
    run_timed_under_half_sec "$T/bin/gh" api f3a_call 2>"$T/f3.err"); rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "f3a-ok" ] && grep -q 'f3a_call' "$F3A"; then
    pass "F3 fresh leftover lock skips rotation without delay ($(cat "$T/f3.err"))"
else
    nope "F3 fresh leftover lock skips rotation without delay" "rc=$rc out=[$out] $(cat "$T/f3.err")"
fi

# F3b: read-only log dir + log over limit completes < 0.5s and gh runs
F3B_DIR=$T/ro_logdir
mkdir -p "$F3B_DIR"
printf '%0350d\n' 1 > "$F3B_DIR/trace.log"
chmod 555 "$F3B_DIR"
out=$(REC=$REC GH_TRACE_LOG="$F3B_DIR/trace.log" GH_TRACE_MAX_BYTES=100 \
    run_timed_under_half_sec "$T/bin/gh" api f3b_call 2>"$T/f3.err"); rc=$?
chmod 755 "$F3B_DIR"
if [ "$rc" -eq 0 ] && [ "$out" = "f3a-ok" ]; then
    pass "F3 read-only log dir does not block or delay gh ($(cat "$T/f3.err"))"
else
    nope "F3 read-only log dir does not block or delay gh" "rc=$rc out=[$out] $(cat "$T/f3.err")"
fi

# F3c: stale lock whose removal fails (read-only parent) completes < 0.5s, gh runs, no orphan
F3C_DIR=$T/ro_staledir
F3C_MARK="f3c_unique_marker_$$"
mkdir -p "$F3C_DIR"
printf '%0350d\n' 1 > "$F3C_DIR/${F3C_MARK}.log"
mkdir "$F3C_DIR/${F3C_MARK}.log.lock"
chmod 555 "$F3C_DIR"
out=$(REC=$REC GH_TRACE_LOG="$F3C_DIR/${F3C_MARK}.log" GH_TRACE_MAX_BYTES=100 GH_TRACE_LOCK_TIMEOUT=0 \
    run_timed_under_half_sec "$T/bin/gh" api "$F3C_MARK" 2>"$T/f3.err"); rc=$?
sleep 0.1
orphans=$(pgrep -f "$F3C_MARK" 2>/dev/null || true)
chmod 755 "$F3C_DIR"
if [ "$rc" -eq 0 ] && [ "$out" = "f3a-ok" ] && [ -z "$orphans" ]; then
    pass "F3 unremovable stale lock does not hang or orphan ($(cat "$T/f3.err"))"
else
    nope "F3 unremovable stale lock does not hang or orphan" "rc=$rc out=[$out] $(cat "$T/f3.err") orphans=[$orphans]"
fi

# F3d: normal rotation when no lock exists
F3D=$T/logs_perm/f3d.log
rm -f "$F3D" "${F3D}.1"
printf '%0350d\n' 1 > "$F3D"
REC=$REC GH_TRACE_LOG=$F3D GH_TRACE_MAX_BYTES=100 "$T/bin/gh" api f3d_call >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ -f "${F3D}.1" ] && [ ! -d "${F3D}.lock" ] && grep -q 'f3d_call' "$F3D"; then
    pass "F3 normal rotation works when no lock exists"
else
    nope "F3 normal rotation works when no lock exists" "rc=$rc"
fi

# 13. missing real gh exits 127
mkdir -p "$T/orphan"
cp "$SHIM_TPL" "$T/orphan/gh"
chmod +x "$T/orphan/gh"
"$T/orphan/gh" api user >"$T/stdout" 2>"$T/stderr"; rc=$?
if [ "$rc" -eq 127 ] && grep -q 'real gh not found' "$T/stderr"; then
    pass "missing real gh exits 127"
else
    nope "missing real gh exits 127" "rc=$rc err=$(cat "$T/stderr")"
fi

# 14. status + non-brew uninstall + idempotency + clobber refusal + rollback
st=$(GH_TRACE_LOG=$LOG "$GT" status "$T/bin/gh" 2>&1); rc=$?
if [ "$rc" -eq 0 ] \
    && grep -q "shim: installed at $T/bin/gh" <<<"$st" \
    && grep -q "real gh: $T/bin/gh.real (exists; gh version 2.65.0" <<<"$st" \
    && grep -q "log: $LOG (" <<<"$st"; then
    pass "status reports non-brew shim, real gh version, and log lines"
else
    nope "status reports non-brew shim, real gh version, and log lines" "rc=$rc st=$st"
fi

out=$("$GT" uninstall "$T/bin/gh" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ -L "$T/bin/gh" ] && [ "$(readlink "$T/bin/gh")" = "$T/real/gh" ] && [ ! -e "$T/bin/gh.real" ]; then
    pass "non-brew uninstall restores original symlink"
else
    nope "non-brew uninstall restores original symlink" "rc=$rc out=$out"
fi

out=$("$GT" uninstall "$T/bin/gh" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ -L "$T/bin/gh" ] && [ "$(readlink "$T/bin/gh")" = "$T/real/gh" ]; then
    pass "non-brew uninstall is idempotent"
else
    nope "non-brew uninstall is idempotent" "rc=$rc out=$out"
fi

printf '#!/bin/sh\necho stale\n' > "$T/bin/gh.real"
"$GT" install "$T/bin/gh" >"$T/stdout" 2>"$T/stderr"; rc=$?
if [ "$rc" -ne 0 ] && [ -L "$T/bin/gh" ] && grep -q 'stale' "$T/bin/gh.real"; then
    pass "install refuses to clobber differing gh.real"
else
    nope "install refuses to clobber differing gh.real" "rc=$rc err=$(cat "$T/stderr")"
fi
"$GT" uninstall "$T/bin/gh" >"$T/stdout" 2>"$T/stderr"; rc=$?
if [ "$rc" -ne 0 ] && [ -L "$T/bin/gh" ] && [ -f "$T/bin/gh.real" ]; then
    pass "uninstall refuses to clobber non-shim when gh.real exists"
else
    nope "uninstall refuses to clobber non-shim when gh.real exists" "rc=$rc err=$(cat "$T/stderr")"
fi
rm -f "$T/bin/gh.real"

cat > "$T/real/broken" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$T/real/broken"
ln -sf "$T/real/broken" "$T/bin/broken_gh"
"$GT" install "$T/bin/broken_gh" >"$T/stdout" 2>"$T/stderr"; rc=$?
if [ "$rc" -ne 0 ] && [ -L "$T/bin/broken_gh" ] && [ "$(readlink "$T/bin/broken_gh")" = "$T/real/broken" ] && [ ! -e "$T/bin/gh.real" ]; then
    pass "non-brew install rolls back when verification fails"
else
    nope "non-brew install rolls back when verification fails" "rc=$rc err=$(cat "$T/stderr")"
fi

# === Homebrew layout tests (fake brew + temp Cellar/opt) ===

BP=$T/brew_prefix
mkdir -p "$BP/bin" "$BP/opt" "$BP/Cellar/gh/2.65.0/bin"
make_fake_gh "$BP/Cellar/gh/2.65.0/bin/gh" "2.65.0"
ln -s "../Cellar/gh/2.65.0" "$BP/opt/gh"
ln -s "../Cellar/gh/2.65.0/bin/gh" "$BP/bin/gh"
BREW_ARGV_LOG=$T/brew_argv
BLOG=$T/logs_perm/brew.log

# 15. brew install unlinks gh, installs POSIX /bin/sh shim pointing to opt/gh/bin/gh, verifies
out=$(FAKE_BREW_PREFIX=$BP BREW_ARGV_LOG=$BREW_ARGV_LOG "$GT" install "$BP/bin/gh" 2>&1); rc=$?
if [ "$rc" -eq 0 ] \
    && [ -f "$BP/bin/gh" ] && [ ! -L "$BP/bin/gh" ] && [ ! -e "$BP/bin/gh.real" ] \
    && head -n 1 "$BP/bin/gh" | grep -q '^#!/bin/sh$' \
    && grep -q "^unlink gh$" "$BREW_ARGV_LOG" \
    && grep -q "GH_TRACE_REAL_DEFAULT='$BP/opt/gh/bin/gh'" "$BP/bin/gh" \
    && grep -q 'Verified: gh version 2.65.0' <<<"$out"; then
    pass "brew install unlinks gh, embeds opt/gh path in /bin/sh shim, verifies"
else
    nope "brew install unlinks gh, embeds opt/gh path in /bin/sh shim, verifies" "rc=$rc out=$out"
fi

# 16. brew shim runs opt gh, sets GH_PATH, logs
reset_rec
ver=$(REC=$REC GH_TRACE_LOG=$BLOG "$BP/bin/gh" --version); rc=$?
out_ghp=$(REC=$REC GH_TRACE_LOG=$BLOG "$BP/bin/gh" api user >/dev/null && cat "$REC/gh_path")
if [ "$rc" -eq 0 ] && [ "$ver" = "gh version 2.65.0 (fake)" ] && [ "$out_ghp" = "$BP/bin/gh" ]; then
    pass "brew shim runs opt/gh/bin/gh, sets GH_PATH, and logs"
else
    nope "brew shim runs opt/gh/bin/gh, sets GH_PATH, and logs" "rc=$rc ver=$ver ghp=$out_ghp"
fi

# 17. simulated brew upgrade: new Cellar 2.66.0, repoint opt/gh, delete old 2.65.0
make_fake_gh "$BP/Cellar/gh/2.66.0/bin/gh" "2.66.0"
rm -f "$BP/opt/gh"
ln -s "../Cellar/gh/2.66.0" "$BP/opt/gh"
rm -rf "$BP/Cellar/gh/2.65.0"

ver=$(REC=$REC GH_TRACE_LOG=$BLOG "$BP/bin/gh" --version); rc=$?
st=$(FAKE_BREW_PREFIX=$BP GH_TRACE_LOG=$BLOG "$GT" status "$BP/bin/gh" 2>&1); st_rc=$?
if [ "$rc" -eq 0 ] && [ "$ver" = "gh version 2.66.0 (fake)" ] \
    && [ "$st_rc" -eq 0 ] \
    && grep -q "shim: installed at $BP/bin/gh (homebrew)" <<<"$st" \
    && grep -q "real gh: $BP/opt/gh/bin/gh (exists; gh version 2.66.0" <<<"$st" \
    && grep -q "log: $BLOG (3 lines)" <<<"$st"; then
    pass "brew shim survives Cellar upgrade and status reflects new version"
else
    nope "brew shim survives Cellar upgrade and status reflects new version" "rc=$rc ver=$ver st_rc=$st_rc st=$st"
fi

# 18. T3 uninstall failure when brew link fails: restores shim, never leaves gh missing
: > "$BREW_ARGV_LOG"
out=$(FAKE_BREW_PREFIX=$BP BREW_ARGV_LOG=$BREW_ARGV_LOG BREW_FAIL_LINK=1 "$GT" uninstall "$BP/bin/gh" 2>&1); rc=$?
ver=$("$BP/bin/gh" --version 2>/dev/null)
if [ "$rc" -ne 0 ] && [ -f "$BP/bin/gh" ] \
    && [ "$ver" = "gh version 2.66.0 (fake)" ] \
    && grep -q 'Manual fix:' <<<"$out"; then
    pass "T3 brew uninstall keeps working shim when brew link fails"
else
    nope "T3 brew uninstall keeps working shim when brew link fails" "rc=$rc ver=$ver out=$out"
fi

# 19. T3 brew uninstall succeeds and restores Cellar symlink; re-run is idempotent
: > "$BREW_ARGV_LOG"
out=$(FAKE_BREW_PREFIX=$BP BREW_ARGV_LOG=$BREW_ARGV_LOG "$GT" uninstall "$BP/bin/gh" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ -L "$BP/bin/gh" ] \
    && [ "$(readlink "$BP/bin/gh")" = "../Cellar/gh/2.66.0/bin/gh" ] \
    && grep -q '^link gh$' "$BREW_ARGV_LOG" \
    && grep -q 'Verified: gh version 2.66.0' <<<"$out"; then
    pass "brew uninstall restores Cellar symlink and verifies"
else
    nope "brew uninstall restores Cellar symlink and verifies" "rc=$rc out=$out"
fi

: > "$BREW_ARGV_LOG"
out=$(FAKE_BREW_PREFIX=$BP BREW_ARGV_LOG=$BREW_ARGV_LOG "$GT" uninstall "$BP/bin/gh" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ -L "$BP/bin/gh" ] && [ ! -s "$BREW_ARGV_LOG" ]; then
    pass "brew uninstall is idempotent when gh is linked"
else
    nope "brew uninstall is idempotent when gh is linked" "rc=$rc brew_calls=$(cat "$BREW_ARGV_LOG") out=$out"
fi

# 19b. T3 re-run when gh is absent and brew keg is unlinked: detects & links gh (and fails if missing)
rm -f "$BP/bin/gh"
out=$(FAKE_BREW_PREFIX=$BP BREW_FAIL_LINK=1 "$GT" uninstall "$BP/bin/gh" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && grep -qi 'unlinked' <<<"$out"; then
    pass "T3 uninstall fails loudly when gh is absent and brew link fails"
else
    nope "T3 uninstall fails loudly when gh is absent and brew link fails" "rc=$rc out=$out"
fi
out=$(FAKE_BREW_PREFIX=$BP "$GT" uninstall "$BP/bin/gh" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ -L "$BP/bin/gh" ]; then
    pass "T3 uninstall recovers absent unlinked brew gh via brew link gh"
else
    nope "T3 uninstall recovers absent unlinked brew gh via brew link gh" "rc=$rc out=$out"
fi

# 20. uninstall refuses to remove a non-shim file
printf '#!/bin/sh\necho custom\n' > "$T/bin/custom_gh"
out=$("$GT" uninstall "$T/bin/custom_gh" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ -f "$T/bin/custom_gh" ] && grep -q 'custom' "$T/bin/custom_gh" && grep -q 'not a gh-trace shim' <<<"$out"; then
    pass "uninstall refuses to remove non-shim file"
else
    nope "uninstall refuses to remove non-shim file" "rc=$rc out=$out"
fi

# 21. brew install rolls back (re-links gh) when opt/gh verification fails
cat > "$BP/Cellar/gh/2.66.0/bin/gh" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$BP/Cellar/gh/2.66.0/bin/gh"
: > "$BREW_ARGV_LOG"
FAKE_BREW_PREFIX=$BP BREW_ARGV_LOG=$BREW_ARGV_LOG "$GT" install "$BP/bin/gh" >"$T/stdout" 2>"$T/stderr"; rc=$?
if [ "$rc" -ne 0 ] && [ -L "$BP/bin/gh" ] \
    && [ "$(readlink "$BP/bin/gh")" = "../Cellar/gh/2.66.0/bin/gh" ] \
    && grep -q '^link gh$' "$BREW_ARGV_LOG"; then
    pass "brew install rolls back via brew link gh on verification failure"
else
    nope "brew install rolls back via brew link gh on verification failure" "rc=$rc err=$(cat "$T/stderr")"
fi

# 22. report output on a small canned log (with - placeholders in cols 4 and 5)
yr=$(date +%Y)
CLOG=$T/canned.log
{
    printf '%s\t%s\t%s\t-\t-\t%s\t%s\t%s\n' \
        "${yr}-11-15T08:48:10+0800" "mac" "101" "/tmp" "/Applications/Orca.app/Contents/MacOS/Orca" "gh api repos/x/y/issues"
    for i in 1 2 3 4 5 6; do
        printf '%s\t%s\t%s\t-\t-\t%s\t%s\t%s\n' \
            "${yr}-11-15T08:51:0${i}+0800" "mac" "$((200 + i))" "/tmp" \
            "/bin/sh -c < /Applications/Orca.app/Contents/MacOS/Orca" \
            "gh api repos/x/y/pulls?state=open&page=${i} -q .[]"
    done
    for i in 1 2 3 4 5; do
        printf '%s\t%s\t%s\t-\t-\t%s\t%s\t%s\n' \
            "${yr}-11-15T08:52:0${i}+0800" "mac" "$((300 + i))" "/tmp" \
            "zsh -lc < node /opt/homebrew/bin/claude" \
            "gh pr view 123"
    done
    for i in 1 2 3 4; do
        printf '%s\t%s\t%s\t-\t-\t%s\t%s\t%s\n' \
            "${yr}-11-15T08:53:0${i}+0800" "mac" "$((400 + i))" "/tmp" \
            "codex --model" "gh api repos/x/y/commits"
    done
    for i in 1 2 3; do
        printf '%s\t%s\t%s\t-\t-\t%s\t%s\t%s\n' \
            "${yr}-11-15T08:53:1${i}+0800" "mac" "$((500 + i))" "/tmp" \
            "bash /Users/test/poll.sh" "gh run list"
    done
    for i in 1 2; do
        printf '%s\t%s\t%s\t-\t-\t%s\t%s\t%s\n' \
            "${yr}-11-15T08:53:2${i}+0800" "mac" "$((600 + i))" "/tmp" \
            "/usr/local/bin/tool5" "gh pr list"
    done
    printf '%s\t%s\t%s\t-\t-\t%s\t%s\t%s\n' \
        "${yr}-11-15T08:53:31+0800" "mac" "701" "/tmp" "/usr/local/bin/tool6" "gh issue list"
} > "$CLOG"

rep=$(GH_TRACE_LOG=$CLOG "$GT" report --since "11-15 08:50" --window 5 2>&1); rc=$?
if [ "$rc" -eq 0 ] \
    && ! grep -q '08:45' <<<"$rep" \
    && grep -q "${yr}-11-15 08:50  total: 21" <<<"$rep" \
    && grep -q '6  /Applications/Orca.app/Contents/MacOS/Orca  (top: gh api repos/x/y/pulls)' <<<"$rep" \
    && grep -q '5  node /opt/homebrew/bin/claude  (top: gh pr view)' <<<"$rep" \
    && grep -q '4  codex' <<<"$rep" \
    && grep -q '3  bash /Users/test/poll.sh' <<<"$rep" \
    && grep -q '2  /usr/local/bin/tool5' <<<"$rep" \
    && ! grep -q 'tool6' <<<"$rep"; then
    pass "report summarizes window, top 5 callers, and stripped argv prefix"
else
    nope "report summarizes window, top 5 callers, and stripped argv prefix" "rc=$rc rep=$rep"
fi

# 23. hygiene: test calls without explicit GH_TRACE_LOG go to $T/default-trace.log, never $REAL_HOME
leaked=''
if [ -f "$REAL_LOG" ]; then
    leaked=$(tail -n "+$((real_lines_before + 1))" "$REAL_LOG" 2>/dev/null | grep -E "gh-trace-test|$T" || true)
fi
if [ -z "$leaked" ] && [ -s "$GH_TRACE_LOG" ]; then
    pass "real HOME gh-trace.log has zero test entries (default went to temp log)"
else
    nope "real HOME gh-trace.log has zero test entries" "leaked=[$leaked] default_size=$(wc -c < "$GH_TRACE_LOG" 2>/dev/null || echo 0)"
fi

exit "$fail"
