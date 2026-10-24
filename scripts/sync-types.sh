#!/usr/bin/env bash
# 升 Claude Code 版本時跑：把本機這版 engine 寫的 API 型別檔抄進 ci/types/，並把 ci/claude-version 改成同一版。
# 型別檔沒有指令能產生，只有 session 載入 plugin-authoring skill 時才會寫到暫存資料夾；找不到就先在
# Claude Code 裡叫一次 plugin-authoring skill（例如問它「mod 的型別檔在哪」），再重跑這支。
set -euo pipefail
cd "$(dirname "$0")/.."
ver=$(claude --version | awk '{print $1}')
src=$(find "${TMPDIR:-/tmp}" /tmp /private/tmp -path "*/bundled-skills/$ver/*/plugin-authoring/types/claude-code.d.ts" 2>/dev/null | head -1 || true)
if [ -z "$src" ]; then
  echo "找不到 $ver 的型別檔：先在 Claude Code 裡載入一次 plugin-authoring skill 再跑。" >&2
  exit 1
fi
cp "$src" ci/types/claude-code.d.ts
echo "$ver" > ci/claude-version
echo "ci/types/claude-code.d.ts ← $src"
echo "ci/claude-version = ${ver}；接著跑 bash scripts/check.sh"
