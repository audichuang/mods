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

- mod（含 `hooks/*.ts(x)`）：`claude plugin test <dir>`、`claude plugin validate <dir>`，型別檢查照 plugin-authoring skill 型別檔開頭的 tsconfig（`strict`、`noUncheckedIndexedAccess`）；prompt-glance 在這個旗標下本來就有一批舊錯，比對改動前的錯誤數，別當成自己弄壞的。測試環境沒有 `setTimeout`；`clock.every` 的替身每回一次 `{ value }` 就是過了一個週期，只想測啟動時那次就回 `{ deny }`。
- `gh-quota` hook：`bash gh-quota/tests/hooktest.sh`，全部 `ok`。改 `gh-quota-guard.py` 前先加案例。
- 整個 marketplace：`claude plugin validate ~/mods`。
- 實際互動 session 驗 mod：這台沒有 tmux，用 `(sleep 60 | script -q /dev/null claude >out 2>&1 &)`，在**已信任**的資料夾開（`~/mods` 尚未信任會卡在信任提示），看 log 或去掉 ANSI 後 grep 輸出。這只證明文字有畫出來，看不出位置；改版面要請使用者截圖確認。

## 發版與部署

1. 行為有變就調 `plugin.json` 的 `version`（只加測試不用）。
2. commit 訊息用繁體中文，格式 `<plugin> <版本>：<改了什麼>`，push 到 `main`。
3. 三台：`git -C ~/mods pull -q --ff-only && claude plugin update <name>@audi-mods`；新增 plugin 用 `claude plugin install <name>@audi-mods`。開著的 session 要 `/reload-plugins`。upall 也會 pull。

## 坑

- 這裡的 `gh-quota` hook 會擋你自己的指令：只要指令文字（含引號內）出現 `gh run watch` 等字樣就會擋。測試資料寫成檔案再餵，或直接跑 `hooktest.sh`。
- 輸入框下方那行（`PromptHint`）排在模式標籤（bypass permissions、auto mode）右邊，不是整行；多列的東西放那裡會擠在標籤旁。整行寬的只有上方的 `AbovePrompt`。
- 同名 plugin 若也放在 `~/.claude/skills/<name>`，會被 `audi-mods` 版蓋掉；不要再用 skills 資料夾裝這裡的 plugin。

## 監控資料

| 檔案 | 內容 |
|---|---|
| `~/.local/state/gh-quota/hook.log` | hook 每擋一次一行 JSON（ts、host、session、cwd、reason、cmd） |
| `~/.local/state/gh-quota/meter.log` | meter 的 start／ok／anon／warn／timeout／fail（狀態變化才寫） |
| `~/.local/state/prompt-glance/hud.log` | HUD 畫在哪（below／above）、讓位原因、session.end 原因、render 錯誤（變化才寫） |
| `~/.local/state/gh-rate.log`（ubuntu） | 時間、core 已用、剩餘、graphql 已用、重置時間 |
