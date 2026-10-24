---
name: gh-quota
description: 等 GitHub Actions／CI 跑完、等 PR checks、checks 過了再合併 PR、查 GitHub API 額度時使用。涵蓋 gh run watch、gh pr checks --watch、輪詢 gh run view／gh pr view、gh pr merge --auto、API rate limit exceeded、HTTP 403、額度用完。用 gh-wait 取代輪詢。
---

# GitHub API 額度

`gh` 的 REST 額度是整個帳號每小時 5000 次，Mac、Mac mini、ubuntu 上所有 agent（Claude、Codex）與排程共用。耗盡時大家的 `gh` 一起失敗，連 CI 裡用個人 token 的步驟也會失敗。

## 等 CI 跑完

用 `gh-wait`，放背景跑，結束時會通知，不要另外輪詢它：

```bash
gh-wait run <run-id> -R owner/repo     # 等一個 workflow run
gh-wait pr <number> -R owner/repo      # 等 PR head commit 的所有 checks
```

- 結束碼：0 成功、1 失敗（`pr` 印出失敗的 check，`run` 印出失敗的 job）、2 參數錯誤、API 錯誤或逾時（stderr 會寫是哪一種，並附上 gh 自己的錯誤訊息）。
- 選項：`-i` 輪詢秒數（預設 15）、`-t` 逾時分鐘（預設 120）。
- 需要 `gh` 和 `jq`；沒有 jq 會立刻說明並結束。
- gh 沒登入會立刻結束（結束碼 2）；網路錯誤或 5xx 會重試，連續 5 次才放棄；額度用完（403／429 且剩 0）會等到重置時間再繼續，不算錯誤。
- 它帶 ETag 做條件請求，狀態沒變時 GitHub 回 304，不扣額度；只有狀態真的變了才算一次。
- 狀態 5 分鐘沒變會印 `unchanged for N min: …`（`pr` 模式會列出還在跑的 check）；一直卡住就是 CI 本身卡死，不是還在正常等。
- `pr` 模式看 head commit 的 check runs（Actions 與其他 GitHub App），不看外部服務的舊式 commit status，最多讀 100 個 check；等待中 PR 又 push，它仍盯著開始時的那個 commit。

## 等 checks 過了就合併

不用等。`gh pr merge <number> --auto --squash`（或 `--merge`），GitHub 會在 required checks 過了之後自己合併。前提是 repo 開了 auto-merge，且目標分支有 required checks；沒有 required checks 時 `--auto` 會立刻合併，不會等 CI。

## 不要做

- `gh run watch`：每輪 2 個請求再加每個執行中 job 1 個，預設 3 秒一輪，一個掛一小時約 2400 次。
- `gh pr checks --watch`：固定間隔輪詢。
- 自寫迴圈輪詢 gh：`while`／`until`／`for` 迴圈裡呼叫 gh 的任何子指令（`api`、`run`、`pr`、`issue`、`workflow`、`release`…，用絕對路徑呼叫也算；只有 `auth`、`config`、`alias`、`completion`、`help`、`version` 不算），且 sleep 少於 60 秒、sleep 的秒數是變數或算式，或是 `while`／`until` 完全沒 sleep。`for` 跑清單、`while read` 讀檔案或管線，只要每個 gh 呼叫都用到迴圈變數（`gh repo clone me/$r`），就算批次，sleep 多短都不擋；gh 沒用到迴圈變數（`for i in $(seq 30); do gh run view 1 …`）就是在輪詢同一個目標，照上面的規則擋。
- `watch … gh`。
- 沒帶 token 的 `curl`／`wget` 打 `api.github.com`：吃的是出口 IP 共用的每小時 60 次匿名額度，改用 `gh api`。token（`Authorization:` header、`$GH_TOKEN`、`$(gh auth token)`）要寫在同一個 curl 指令裡才算。

這些會被 plugin 的 hook 擋下，包括寫在 `-R owner/repo` 後面、包在 `bash -c '…'`／`sh -c`／`ssh host '…'`／`eval '…'` 裡的（遠端沒有 hook）。

## 查額度

`gh api rate_limit --jq .resources.core`（這個端點本身不扣額度）。ubuntu 每 5 分鐘把用量記在 `~/.local/state/gh-rate.log`（時間、已用、剩餘、GraphQL 已用、重置時間）。

## 監控（持續優化用）

各台記各自的，放在 `~/.local/state/gh-quota/`：

- `hook.log`：hook 每擋一次寫一行 JSON（ts、host、session、cwd、reason、cmd）。看誤擋或常犯的寫法：`tail -n 50 ~/.local/state/gh-quota/hook.log | jq -c '{ts,reason,cmd}'`，按原因統計：`jq -r .reason ~/.local/state/gh-quota/hook.log | sort | uniq -c | sort -rn`。超過 1 MB 輪替成 `hook.log.1`。
- `meter.log`：狀態列 mod 的事件，tab 分隔（時間、事件、細節）。事件有 `start`（每個互動 session 開始記一次）、`warn`（額度偏低，每個重置週期一次），以及查詢結果 `ok`、`anon`（gh 沒登入，看到的是匿名額度）、`no-gh`、`timeout`、`fail`、`bad-output`（這六種只在類型改變時記）；保留最後 500 行。
- ubuntu 另有 `~/.local/state/gh-rate.log`：每 5 分鐘整個帳號的用量，用來對時間找出是誰在燒額度。

看到誤擋就把那條指令加進 `tests/hooktest.sh` 當 allow 案例再修 hook；看到漏擋就加 DENY 案例。gh-wait 的行為測在 `tests/gh-wait-test.sh`（假的 gh 放 PATH 最前面）。
