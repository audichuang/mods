#!/usr/bin/env bash
# audi-mods 的品質關卡：本機與 CI 跑同一份。
#   bash scripts/check.sh            全部檢查
#   BASE=<commit> bash scripts/check.sh   另外檢查「改了 plugin 卻沒調 version」
# 需要：claude、python3、node（npx 抓 typescript）；shellcheck 有就跑，CI 一定有。
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PINNED=$(cat ci/claude-version)
TS=typescript@5.9.3
fails=()
step() { printf '\n== %s\n' "$*"; }
fail() { echo "FAIL: $*"; fails+=("$*"); }

# 有 .claude-plugin/plugin.json 的資料夾都是 plugin；有 hooks module 的叫 mod
plugins=(); mods=()
for d in */; do
  d=${d%/}
  [ -f "$d/.claude-plugin/plugin.json" ] || continue
  plugins+=("$d")
  python3 -c 'import json,sys;sys.exit(0 if json.load(open(sys.argv[1])).get("modules") else 1)' "$d/hooks/hooks.json" 2>/dev/null && mods+=("$d")
done

step "版本"
have=$(claude --version | awk '{print $1}')
echo "claude ${have}（釘選 ${PINNED}）"
[ "$have" = "$PINNED" ] || echo "注意：本機 claude 版本與 ci/claude-version 不同，CI 用的是 $PINNED"
types_ver=$(head -1 ci/types/claude-code.d.ts | sed -E 's/.*Claude Code ([0-9]+(\.[0-9]+)*).*/\1/')
[ "$types_ver" = "$PINNED" ] || fail "ci/types/claude-code.d.ts 是 $types_ver 寫的，ci/claude-version 是 ${PINNED}：跑 scripts/sync-types.sh"

step "manifest 與 marketplace 一致"
python3 - "${plugins[@]}" <<'EOF' || fail "manifest 一致性"
import json, os, sys
bad = 0
def err(msg):
    global bad; bad = 1; print("  " + msg)
m = json.load(open(".claude-plugin/marketplace.json"))
listed = {p["name"]: p["source"] for p in m["plugins"]}
for d in sys.argv[1:]:
    pj = json.load(open(f"{d}/.claude-plugin/plugin.json"))
    if pj.get("name") != d: err(f"{d}: plugin.json name 是 {pj.get('name')!r}")
    if not pj.get("version"): err(f"{d}: plugin.json 沒有 version")
    if listed.get(d) != f"./{d}": err(f"{d}: marketplace.json 沒列，或 source 不是 ./{d}")
    hj = f"{d}/hooks/hooks.json"
    if os.path.exists(hj):
        h = json.load(open(hj))
        for mod in h.get("modules", []):
            if not os.path.isfile(os.path.join(d, "hooks", mod)): err(f"{hj}: module {mod} 不存在")
for name, src in listed.items():
    if not os.path.isfile(os.path.join(src, ".claude-plugin/plugin.json")): err(f"marketplace.json 列了 {name}，{src} 卻不是 plugin")
sys.exit(bad)
EOF

step "claude plugin validate --strict"
claude plugin validate --strict . >/dev/null 2>&1 || { claude plugin validate --strict . ; fail "validate marketplace"; }
for p in "${plugins[@]}"; do
  if out=$(claude plugin validate --strict "$p" 2>&1); then echo "ok   $p"; else echo "$out"; fail "validate $p"; fi
done

step "claude plugin test（mod）"
for p in "${mods[@]}"; do
  if out=$(CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 claude plugin test "$p" 2>&1); then
    echo "ok   ${p}：$(echo "$out" | grep -E '^ *[0-9]+ pass' | tr -s ' ')"
  else echo "$out"; fail "plugin test $p"; fi
done

step "型別檢查（官方 strict tsconfig + ci/types）"
# 型別檔只有 engine 載入 mod 時才會寫進 .claude-plugin/types/（gitignore），CI 拿不到，所以用 repo 裡的 ci/types。
# ci/tsc-baseline 記著還沒清掉的舊錯數：只准變少，變少時把數字改小。
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
for p in "${mods[@]}"; do
  inc="\"$PWD/ci/types\""
  for sub in hooks types tests; do [ -d "$p/$sub" ] && inc+=",\"$PWD/$p/$sub\""; done
  cat > "$tmp/$p.json" <<EOF
{"compilerOptions":{"target":"es2023","lib":["es2023"],"types":[],"module":"esnext","moduleResolution":"bundler",
"strict":true,"noUncheckedIndexedAccess":true,"noEmit":true,"skipLibCheck":true,
"jsx":"react","jsxFactory":"h","jsxFragmentFactory":"Fragment"},"include":[$inc]}
EOF
  n=$(npx -y -p "$TS" tsc -p "$tmp/$p.json" 2>&1 | tee "$tmp/$p.out" | grep -c 'error TS')
  base=$(awk -v p="$p" '$1==p{print $2}' ci/tsc-baseline 2>/dev/null); base=${base:-0}
  if [ "$n" -gt "$base" ]; then cat "$tmp/$p.out"; fail "tsc ${p}：$n 個錯（基準 ${base}）"
  elif [ "$n" -lt "$base" ]; then echo "ok   ${p}：$n 個錯，比基準 $base 少，把 ci/tsc-baseline 改成 $n"
  else echo "ok   ${p}：$n 個錯${base:+（基準 ${base}）}"; fi
done

step "gh-quota（Python command hook 與 bash）"
python3 -B -c 'import ast,sys;[ast.parse(open(f).read(),f) for f in sys.argv[1:]]' gh-quota/hooks/*.py || fail "gh-quota Python 語法"
if out=$(bash gh-quota/tests/hooktest.sh 2>&1) && ! grep -qv '^ok ' <<<"$out"; then
  echo "ok   hooktest：$(grep -c '^ok ' <<<"$out") 個案例"
else echo "$out" | grep -v '^ok '; fail "gh-quota hooktest"; fi
if command -v shellcheck >/dev/null; then
  shellcheck -S warning gh-quota/bin/gh-wait gh-quota/tests/*.sh scripts/*.sh && echo "ok   shellcheck" || fail "shellcheck"
else echo "略過 shellcheck（沒裝；CI 會跑）"; fi

step "repo 衛生"
junk=$(git ls-files | grep -E '(__pycache__/|\.pyc$|\.claude-plugin/types/|\.DS_Store$)')
[ -z "$junk" ] && echo "ok   沒有不該進 git 的檔" || { echo "$junk"; fail "git 裡有產生檔"; }

if [ -n "${BASE:-}" ] && git cat-file -e "$BASE" 2>/dev/null; then
  step "改了 plugin 就要調 version（對比 ${BASE}）"
  for p in "${plugins[@]}"; do
    changed=$(git diff --name-only "$BASE" HEAD -- "$p" | grep -vE "^$p/(tests/|README\.md$|LICENSE$|\.claude-plugin/plugin\.json$|.*\.test\.tsx?$|.*__pycache__/.*|.*\.pyc$)")
    [ -z "$changed" ] && continue
    old=$(git show "$BASE:$p/.claude-plugin/plugin.json" 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin).get("version",""))' 2>/dev/null)
    new=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$p/.claude-plugin/plugin.json")
    if [ -n "$old" ] && [ "$old" = "$new" ]; then fail "$p 改了行為檔卻沒調 version（仍是 ${new}）：$(echo $changed)"; else echo "ok   $p ${old:-新} → $new"; fi
  done
fi

echo
if [ ${#fails[@]} -eq 0 ]; then echo "全部通過"; exit 0; fi
echo "${#fails[@]} 項沒過："; printf '  - %s\n' "${fails[@]}"; exit 1
