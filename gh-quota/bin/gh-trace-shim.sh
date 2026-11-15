#!/bin/sh
# gh-trace-shim-v1
# POSIX /bin/sh shim: logs who/what/when (not duration/exit), then execs real gh.
GH_TRACE_REAL_DEFAULT=''
# shellcheck disable=SC2034
GH_TRACE_MODE=''

self_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)
shim_path="${self_dir}/${0##*/}"

if [ -n "${GH_TRACE_REAL:-}" ]; then
    real=$GH_TRACE_REAL
elif [ -n "$GH_TRACE_REAL_DEFAULT" ]; then
    real=$GH_TRACE_REAL_DEFAULT
else
    real="${self_dir}/gh.real"
fi

if [ ! -x "$real" ]; then
    printf 'gh-trace: real gh not found or not executable: %s\n' "$real" >&2
    exit 127
fi

# Logging runs in a subshell so failures never affect gh or pollute stdout/stderr.
(
    umask 077
    log=${GH_TRACE_LOG:-$HOME/.local/state/gh-quota/gh-trace.log}
    log_dir=$(dirname -- "$log")
    [ -d "$log_dir" ] || mkdir -p "$log_dir"

    max_bytes=${GH_TRACE_MAX_BYTES:-20971520}
    if [ -f "$log" ]; then
        sz=$(wc -c < "$log" 2>/dev/null)
        sz=$((sz + 0))
        if [ "$sz" -gt "$max_bytes" ] 2>/dev/null; then
            lock="${log}.lock"
            if mkdir "$lock" 2>/dev/null; then
                if [ -f "$log" ]; then
                    sz=$(wc -c < "$log" 2>/dev/null)
                    sz=$((sz + 0))
                    if [ "$sz" -gt "$max_bytes" ] 2>/dev/null; then
                        mv -f "$log" "${log}.1" 2>/dev/null || true
                    fi
                fi
                rmdir "$lock" 2>/dev/null || rm -rf "$lock" 2>/dev/null || true
            else
                stale_sec=${GH_TRACE_LOCK_TIMEOUT:-10}
                now=$(date +%s 2>/dev/null || echo 0)
                case $(uname -s 2>/dev/null) in
                    Darwin) mtime=$(stat -f%m "$lock" 2>/dev/null || echo "$now") ;;
                    *)      mtime=$(stat -c%Y "$lock" 2>/dev/null || echo "$now") ;;
                esac
                if [ $((now - mtime)) -ge "$stale_sec" ] 2>/dev/null; then
                    rmdir "$lock" 2>/dev/null || rm -rf "$lock" 2>/dev/null || true
                fi
            fi
        fi
    fi

    redact_text() {
        case $1 in
            *[Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn]*|*gh[pousr]_*|*github_pat_*|*GH_TOKEN=*|*GITHUB_TOKEN=*|*[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]=*|*[Pp][Aa][Ss][Ss][Ww][Dd]=*|*[Ss][Ee][Cc][Rr][Ee][Tt]=*|*[Tt][Oo][Kk][Ee][Nn]=*|*[Kk][Ee][Yy]=*)
                printf '%s\n' "$1" | sed -E \
                    -e 's/(GH_TOKEN|GITHUB_TOKEN)=[^ ]+/\1=[REDACTED]/g' \
                    -e 's/(gh[pousr]|github_pat)_[A-Za-z0-9_]+/[REDACTED]/g' \
                    -e 's/([Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn]:[ ]*)([Bb][Ee][Aa][Rr][Ee][Rr][ ]+|[Tt][Oo][Kk][Ee][Nn][ ]+|[Bb][Aa][Ss][Ii][Cc][ ]+)?[^ ]+/\1[REDACTED]/g' \
                    -e 's/([A-Za-z0-9_]*([Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Pp][Aa][Ss][Ss][Ww][Dd]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Tt][Oo][Kk][Ee][Nn]|[Kk][Ee][Yy]))=[^ ]+/\1=[REDACTED]/g'
                ;;
            *)
                printf '%s\n' "$1"
                ;;
        esac
    }

    is_sensitive_key() {
        case $(printf '%s' "$1" | tr '[:upper:]' '[:lower:]') in
            *password*|*passwd*|*secret*|*token*|*key*) return 0 ;;
            *) return 1 ;;
        esac
    }

    chain=''
    pid=$PPID
    depth=0
    while [ "$depth" -lt 4 ] && [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null; do
        line=$(ps -ww -o ppid=,command= -p "$pid" 2>/dev/null || ps -o ppid=,command= -p "$pid" 2>/dev/null) || break
        nppid=${line#"${line%%[! ]*}"}
        nppid=${nppid%% *}
        cmd=${line#*[0-9] }
        cmd=${cmd#"${cmd%%[! ]*}"}
        cmd=$(printf '%s' "$cmd" | tr '\t\r\n' '   ')
        [ -n "$cmd" ] || break
        w1=${cmd%% *}
        rest=${cmd#"$w1"}
        rest=${rest#"${rest%%[! ]*}"}
        if [ -n "$rest" ]; then
            w2=${rest%% *}
            cmd="$w1 $w2"
        else
            cmd=$w1
        fi
        cmd=$(redact_text "$cmd" | cut -c1-120)
        chain=${chain:+"$chain < "}$cmd
        [ -n "$nppid" ] && [ "$nppid" != "$pid" ] || break
        pid=$nppid
        depth=$((depth + 1))
    done

    argv=''
    if { [ "${1:-}" = "secret" ] || [ "${1:-}" = "variable" ]; } && [ "${2:-}" = "set" ]; then
        sv_sub="$1 $2"
        shift 2
        sv_name=''
        sv_skip=0
        for a in "$@"; do
            if [ "$sv_skip" -eq 1 ]; then
                sv_skip=0
                continue
            fi
            case $a in
                -R|--repo|-e|--env|-o|--org|-a|--app|-b|--body|-f|--env-file|-r|--repos|-v|--visibility)
                    sv_skip=1 ;;
                -*) ;;
                *)
                    sv_name=$(printf '%s' "$a" | tr '\t\r\n' '   ')
                    break ;;
            esac
        done
        argv="gh $sv_sub${sv_name:+ $sv_name}"
    else
        argv='gh'
        prev=''
        for a in "$@"; do
            a=$(printf '%s' "$a" | tr '\t\r\n' '   ')
            case $prev in
                body)
                    a='[REDACTED]'
                    prev='' ;;
                hdr)
                    case $a in
                        [Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn]:*) a="${a%%:*}: [REDACTED]" ;;
                        [Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn]*)  a='Authorization [REDACTED]' ;;
                    esac
                    prev='' ;;
                field)
                    case $a in
                        *=*)
                            fk=${a%%=*}
                            if is_sensitive_key "$fk"; then
                                a="${fk}=[REDACTED]"
                            fi ;;
                    esac
                    prev='' ;;
                *)
                    case $a in
                        -b|--body)
                            prev='body' ;;
                        --body=*)
                            a='--body=[REDACTED]' ;;
                        -H|--header)
                            prev='hdr' ;;
                        -H[Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn]:*|--header=[Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn]:*)
                            a="${a%%:*}: [REDACTED]" ;;
                        -f|-F|--field|--raw-field)
                            prev='field' ;;
                        --field=*|--raw-field=*)
                            fprefix=${a%%=*}
                            frest=${a#*=}
                            case $frest in
                                *=*)
                                    fk=${frest%%=*}
                                    if is_sensitive_key "$fk"; then
                                        a="${fprefix}=${fk}=[REDACTED]"
                                    fi ;;
                            esac ;;
                        -f*=*|-F*=*)
                            fprefix=${a%%=*}
                            fk=${fprefix#??}
                            if is_sensitive_key "$fk"; then
                                a="${fprefix}=[REDACTED]"
                            fi ;;
                    esac ;;
            esac
            argv="$argv $a"
        done
    fi

    argv=$(redact_text "$argv" | cut -c1-400)
    cwd=$(printf '%s' "$PWD" | tr '\t\r\n' '   ')
    host=$(hostname 2>/dev/null || echo unknown)
    ts=$(date +%Y-%m-%dT%H:%M:%S%z 2>/dev/null)

    printf '%s\t%s\t%s\t-\t-\t%s\t%s\t%s\n' \
        "$ts" "$host" "$$" "$cwd" "${chain:--}" "$argv" >> "$log"
) 2>/dev/null || true

GH_PATH=$shim_path
export GH_PATH
exec "$real" "$@"
