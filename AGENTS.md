# audi-mods

使用者個人的 Claude Code marketplace（https://github.com/audichuang/mods，公開）。每個子資料夾是一個 plugin，`.claude-plugin/marketplace.json` 列出全部。三台機器都 clone 在 `~/mods`，註冊成**資料夾型** marketplace `audi-mods`：就地讀取，`git pull` 就是部署。

## 機器

| 機器 | 從這台怎麼連 | 備註 |
|---|---|---|
| Mac mini（`AudideMac-mini`） | 本機或 `audimacmini`（tailscale） | |
| MacBook Pro（`MacBook-Pro-6`，使用者 `audi`） | `ssh macbookpro` | SSH 進去讀不到鑰匙圈，`gh` 會變匿名（60 次） |
| ubuntu | `ssh ubuntu` | cron 每 5 分鐘寫 `~/.local/state/gh-rate.log` |

遠端登入 shell 可能是 fish：指令一律包 `bash -s`／`bash -c`，macOS 要補 `PATH=/opt/homebrew/bin:$PATH`。

## 驗證

- push 前跑 `bash scripts/check.sh`（要比對 version 有沒有調就加 `BASE=origin/main`），全綠才推；CI（`.github/workflows/ci.yml`）在 push／PR 跑同一支，每週一另用最新版 Claude Code 跑一次。它包含：marketplace 與每個 plugin 的 `claude plugin validate --strict`、每個 mod 的 `claude plugin test`、官方 strict tsconfig 的 `tsc`、`gh-quota/tests/*.sh`（hook 案例與 gh-wait 假 gh 測試）、shellcheck、manifest 一致性、產生檔沒進 git、改了 plugin 有調 version。
- 型別檢查用 repo 裡的 `ci/types/claude-code.d.ts`（`.claude-plugin/types/` 只有 engine 載入時才寫、而且 gitignore，CI 拿不到）。升 Claude Code 後跑 `scripts/sync-types.sh` 同步型別檔和 `ci/claude-version`。`ci/tsc-baseline` 記某個 mod 還沒清掉的舊錯數（目前全清，檔案是空的）：只准變少，修掉就把數字改小。
- 新增 mod：資料夾裡有 `.claude-plugin/plugin.json` 就會被 check.sh 撿到，`hooks/hooks.json` 有 `modules` 就當 mod 跑 test 和 tsc；`plugin.json` 要有 `author`，不然 `--strict` 不過。
- 測試環境沒有 `setTimeout`。要測計時器的多個週期用 `claude-code/testing` 的 `mock.clock(on)` 再 `advance`；只測啟動時那次，就自己 `on('clock.every', …)` 回 `{ deny }`。
- `gh-quota`：改 `gh-quota-guard.py` 前先在 `hooktest.sh` 加案例（可寫 `DENY:<理由片段>` 斷言理由）；改 `bin/gh-wait` 前先在 `gh-wait-test.sh` 加案例。
- `gh-quota-guard.py` 是擋 agent 順手寫出的輪詢，不是安全邊界：審查找到刻意構造的繞過（多層 `bash -c`、跳脫空格、單引號裡的字面 `$i`）歸 Noted，不再加解析層；用 regex 解析 shell 每補一處就多一處邊界，批次判斷別退回「認出重導向再刪掉」的做法。
- 實際互動 session 驗 mod：這台沒有 tmux，用 `(sleep 60 | script -q /dev/null claude >out 2>&1 &)`，在**已信任**的資料夾開（`~/mods` 尚未信任會卡在信任提示），看 log 或去掉 ANSI 後 grep 輸出。這只證明文字有畫出來，看不出位置；改版面要請使用者截圖確認。

## 發版與部署

1. 行為有變就調 `plugin.json` 的 `version`（只加測試不用）。
2. commit 訊息用繁體中文，格式 `<plugin> <版本>：<改了什麼>`，push 到 `main`。
3. 三台：`git -C ~/mods pull -q --ff-only && claude plugin update <name>@audi-mods`；新增 plugin 用 `claude plugin install <name>@audi-mods`。開著的 session 要 `/reload-plugins`。upall 也會 pull。

## 坑

- 這裡的 `gh-quota` hook 會擋你自己的指令：只要指令文字（含引號內）出現 `gh run watch` 等字樣就會擋。測試資料寫成檔案再餵，或直接跑 `hooktest.sh`。
- 輸入框下方那行（`PromptHint`）排在模式標籤（bypass permissions、auto mode）右邊，不是整行；多列的東西放那裡會擠在標籤旁。整行寬的只有上方的 `AbovePrompt`。
- `scripts/*.sh` 裡變數後面緊接中文要寫 `${var}`：bash 會把 `$have（` 的全形字元讀進變數名，報 unbound variable，shellcheck 抓不到。
- 同名 plugin 若也放在 `~/.claude/skills/<name>`，會被 `audi-mods` 版蓋掉；不要再用 skills 資料夾裝這裡的 plugin。

## 監控資料

| 檔案 | 內容 |
|---|---|
| `~/.local/state/gh-quota/hook.log` | hook 每擋一次一行 JSON（ts、host、session、cwd、reason、cmd） |
| `~/.local/state/gh-quota/meter.log` | meter 的事件：start（每個互動 session 一次）、warn（每個重置時段一次）、ok／anon／no-gh／timeout／fail／bad-output（種類變了才寫）；anon 是匿名額度或 gh 從沒登入（exit 4）；保留最後 500 行 |
| `~/.local/state/prompt-glance/hud.log` | HUD 畫在哪（below／above）、讓位原因、session.end 原因、render 錯誤（變化才寫） |
| `~/.local/state/gh-rate.log`（ubuntu） | 時間、core 已用、剩餘、graphql 已用、重置時間 |
