---
name: gh-quota
description: 等 GitHub Actions／CI 跑完、等 PR checks、checks 過了再合併 PR、查 GitHub API 額度時使用。涵蓋 gh run watch、gh pr checks --watch、輪詢 gh run view／gh pr view、gh pr merge --auto、API rate limit exceeded、HTTP 403、額度用完。用 gh-wait 取代輪詢。
---

# GitHub API 額度

`gh` 的 REST 額度是整個帳號每小時 5000 次，Mac、Mac mini、ubuntu 上所有 agent（Claude、Codex）與排程共用。耗盡時大家的 `gh` 一起失敗，連 CI 裡用個人 token 的步驟也會失敗。

## 等 CI 跑完

push 完，在那個 checkout 直接跑 `gh-wait`，不帶參數，放背景，結束時會通知。不要先 `sleep` 再 `gh run list` 找 run id：

```bash
gh-wait                                # 剛 push 的 HEAD：有 open PR 就等 PR，沒有（push 到 main、tag）就等這個 commit
gh-wait -C ../other-worktree           # checkout 在別的目錄
gh-wait --workflow release.yml         # 只等某個 workflow 的 run（tag push 觸發的 release 也適用）
gh-wait --ignore 'windows-*'           # 已知會掛或卡住的 check 不算數
```

已經知道目標時：

```bash
gh-wait run <run-id> -R owner/repo     # 等一個 workflow run
gh-wait pr <number> -R owner/repo      # 等 PR head commit 的所有 checks
gh-wait commit <sha> -R owner/repo     # 等一個 commit 的所有 checks（run 還沒建出來也會等；短 sha 可以）
gh-wait tag <tag> -R owner/repo --workflow release.yml   # 等 tag push 觸發的 release run
```

推的不是目前 HEAD 時（`git push <remote> <sha>:refs/heads/main <tag>`、`gh pr merge` 在 GitHub 上合併、從另一個 checkout 推），不帶參數會因為「HEAD is not pushed」結束：改用上面這幾行，指名剛推的 commit、tag 或 run。

- 不帶參數時，它從 push 的 remote 判斷 repo：先找 push repo 上這個分支的 open PR，fork 上沒有就去上游（parent）找；HEAD 還沒 push 會直接結束（結束碼 2），請先 push。只認 github.com 的 remote（SSH 別名用本機 `ssh -G` 確認），其他 remote 退回 `gh repo view`。stderr 第一行寫它選了哪個目標。
- tag push 觸發的 release 一定要加 `--workflow <檔名>`：`gh-wait tag` 不帶會直接以 usage 錯誤結束（結束碼 2），因為 main 那次 push 的 CI 已經全綠、release 的 run 還沒建出來時會直接回 0。tag 不是目前 HEAD 時用 `gh-wait tag <tag> --workflow <檔名>`：它只追這個 tag push 開的 run，同一個 commit 先前 branch push 跑的同一支 workflow 不算。
- `commit`／`tag` 沒帶 `-R` 時，依序決定 repo：① remote-tracking ref 含有這個 commit 的 remote（只有一個 repo 時）；② push remote（分支的 `pushRemote`、`remote.pushDefault`、分支的 remote；detached HEAD 只看 `remote.pushDefault`），而且它的 push URL 要是 GitHub repo（`DISABLED` 或非 GitHub 就跳過）；③ 最後才退回 `gh repo view`。fork 的 checkout 裡 `gh repo view` 常是上游，而上游對 fork 的 commit 會回 200、0 個 check，以前會一路等到逾時；fork 的分支被改寫後沒有任何 remote-tracking ref 含有該 commit，就靠②選 fork。stderr 第一行在第一次 API 呼叫之前就寫 `on owner/repo (from -R|remote <名>|push remote <名>|gh repo view)`（明確的 `pr <n>` 也一樣），看到不對就停掉改帶 `-R`。
- 等了 10 分鐘（`GH_WAIT_NOCHECKS`）這個 commit 都沒有任何 check、也沒有排隊中或執行中的 Actions suite（已完成的不算；或 `--workflow` 一直沒有 run），就回 2 並提示帶 `-R`：通常是等錯 repo。
- 跑的時候狀態有變化就印一行進度（run 與 `--workflow` 是 `jobs 3/7 done, running: …`，pr／commit 是 `wait:N running (…)`）；結束時印 run 或失敗 check 的 URL，失敗時附上最多 3 個失敗 job 的 log 尾巴（`--log-lines N`，預設 40，0 關掉）。不用另外抓 log 或查 jobs。
- `--ignore <glob>` 可重複：符合的 check 不等、失敗也不算。非忽略的都完成、只剩被忽略的還在跑時，再等 30 秒（`GH_WAIT_GRACE`）看有沒有新 check 出現，沒有就收工。
- `--workflow` 會等所有符合的 run（同一個 commit 可能同時有 push 與 pull_request 兩個 run），全部成功才回 0；第一個跑完後會再列一次，之後才出現的 run 不追。

- 一律放背景（`run_in_background`）。前景會被 Bash 工具的 10 分鐘上限砍掉，`timeout` 設再大也一樣；不要接 `| tail`：它的輸出本來就短，背景任務結束時回報的就是 gh-wait 的結束碼；接了 pipe 就變成 tail 的，而 macOS 上 agent 的 shell 是 zsh，沒有 `PIPESTATUS` 可以補救。也不要在後面加 `; echo $?`、`echo rc=$?`：結束碼會變成 echo 的 0，失敗被藏起來；gh-wait 自己會印結果，通知帶的就是真的結束碼。專案規定要前景等（例如 Orca 會把閒置的 run 當成結束而關掉 terminal）時，照專案用 `-t 9` 前景跑，一樣不接 pipe；回 2 且 stderr 有 `timeout after` 就再叫一次。
- 等通知就好：通知來之前不讀它的輸出檔、不 `pgrep`、不另外跑 `gh run view`／`gh pr checks`，那些都是在它旁邊再打一次 API。
- push 完馬上等 PR：GitHub 可能還回報舊的 head commit，它的 checks 早就跑完了，會讀到舊結果。在 PR 分支的 checkout 裡跑，分支有 upstream 或 pushRemote 指向 PR 的 head repo（`git push -u` 過），且 HEAD 已經 push 時，`gh-wait pr` 會自己等 PR head 變成 HEAD，最多 2 分鐘，等不到（例如 PR 已被 Update branch 推得更新）就改看 PR 當下的 head，並在 stderr 註明。其他情況（不在那個 checkout、push 時沒加 `-u`）帶 `--sha <剛推的 commit>`，它會一直等到 PR head 變成那個 commit 或逾時。不要用 `sleep` 墊時間。

- 同一個 commit 重跑過 CI（例如把 PR 先關再開）時，舊那輪失敗的 check suite 還掛在這個 commit 上，`gh-wait pr` 會把它算進去而回報失敗。先查新那輪的 run id,改用 `gh-wait run <新 run id>` 等。

- 結束碼：0 成功、1 失敗（`pr` 印出失敗的 check，`run` 印出失敗的 job）、2 參數錯誤、API 錯誤或逾時（stderr 會寫是哪一種，並附上 gh 自己的錯誤訊息）。
- 選項：`-i` 輪詢秒數（預設 15）、`-t` 逾時分鐘（預設 120）、`--sha`（只有 `pr`：先等 PR head 變成這個 commit，可給短 sha）、`-C`、`--workflow`、`--ignore`、`--log-lines`（見上）。
- 需要 `gh` 和 `jq`；沒有 jq 會立刻說明並結束。
- gh 沒登入會立刻結束（結束碼 2）；網路錯誤或 5xx 會重試，連續 5 次才放棄；額度用完（403／429 且剩 0）會等到重置時間再繼續，不算錯誤（一開始讀 PR head 那次也一樣）。
- 它帶 ETag 做條件請求，狀態沒變時 GitHub 回 304，不扣額度；只有狀態真的變了才算一次。
- 狀態 5 分鐘沒變會印 `unchanged for N min: …`（`pr` 模式會列出還在跑的 check）；一直卡住就是 CI 本身卡死，不是還在正常等。
- `pr` 模式看 head commit 的 check runs（Actions 與其他 GitHub App），不看外部服務的舊式 commit status，最多讀 100 個 check；開始等 checks 之後 PR 又 push，它仍盯著原本那個 commit。每次 check runs 全綠時都會再查一次 check suites（這段空檔每輪多花 1 次請求），有 check run 的 suite 都跑完才算成功，所以 `needs:` 的後續 job 還沒建出 check run 時會印 `wait:N workflow still running` 繼續等，不會提早回 0。

## 等 checks 過了就合併

不用等。`gh pr merge <number> --auto --squash`（或 `--merge`），GitHub 會在 required checks 過了之後自己合併。前提是 repo 開了 auto-merge，且目標分支有 required checks；沒有 required checks 時 `--auto` 會立刻合併，不會等 CI。

## 不要做

- `gh run watch`：每輪 2 個請求再加每個執行中 job 1 個，預設 3 秒一輪，一個掛一小時約 2400 次。
- `gh pr checks --watch`：固定間隔輪詢。
- 自寫迴圈輪詢 gh：`while`／`until`／`for` 迴圈裡呼叫 gh 的任何子指令（`api`、`run`、`pr`、`issue`、`workflow`、`release`…，用絕對路徑呼叫也算；只有 `auth`、`config`、`alias`、`completion`、`help`、`version` 不算），且 sleep 少於 60 秒、sleep 的秒數是變數或算式，或是 `while`／`until` 完全沒 sleep。`for` 跑清單、`while read` 讀檔案或管線，只要每個 gh 呼叫都用到迴圈變數（`gh repo clone me/$r`），就算批次，sleep 多短都不擋；gh 沒用到迴圈變數（`for i in $(seq 30); do gh run view 1 …`）就是在輪詢同一個目標，照上面的規則擋。
- `watch … gh`。
- 沒帶 token 的 `curl`／`wget` 打 `api.github.com`：吃的是出口 IP 共用的每小時 60 次匿名額度，改用 `gh api`。token（`Authorization:` header、`$GH_TOKEN`、`$(gh auth token)`）要寫在同一個 curl 指令裡才算。

這些會被 plugin 的 hook 擋下，包括寫在 `-R owner/repo` 後面、包在 `bash -c '…'`／`sh -c`／`ssh host '…'`／`eval '…'`、函式或 `{ …; }` 裡的（遠端沒有 hook）。擋下時訊息會依你在輪詢的東西給出該換成的 gh-wait 指令。

## 查額度

`gh api rate_limit --jq .resources.core`（這個端點本身不扣額度）。ubuntu 每 5 分鐘把用量記在 `~/.local/state/gh-rate.log`（時間、已用、剩餘、GraphQL 已用、重置時間）。

## 監控（持續優化用）

各台記各自的，放在 `~/.local/state/gh-quota/`：

- `hook.log`：hook 每擋一次寫一行 JSON（ts、host、session、cwd、reason、cmd，cmd 最多 8000 字）。看誤擋或常犯的寫法：`tail -n 50 ~/.local/state/gh-quota/hook.log | jq -c '{ts,reason,cmd}'`，按原因統計：`jq -r .reason ~/.local/state/gh-quota/hook.log | sort | uniq -c | sort -rn`。超過 1 MB 輪替成 `hook.log.1`。
- `meter.log`：狀態列 mod 的事件，tab 分隔（時間、事件、細節）。事件有 `start`（每個互動 session 開始記一次）、`warn`（額度偏低，每個重置週期一次），以及查詢結果 `ok`、`anon`（gh 沒登入，看到的是匿名額度）、`no-gh`、`timeout`、`fail`、`bad-output`（這六種只在類型改變時記）；保留最後 500 行。
- ubuntu 另有 `~/.local/state/gh-rate.log`：每 5 分鐘整個帳號的用量，用來對時間找出是誰在燒額度。
- `gh-trace.log`：裝了 `gh-trace` 時，每次 gh 呼叫一行（時間、host、pid、cwd、呼叫者鏈、argv；秘密已遮蔽）。它裝在系統 gh 的位置，所有呼叫者（Claude、Codex、桌面 app、腳本）都會經過，只記錄不攔。`gh-trace install` 安裝、`gh-trace status` 看狀態、`gh-trace report --window 5` 依時段列出前幾名呼叫者、`gh-trace uninstall` 移除；裝上去的 shim 是複製的檔案，改了 `gh-trace-shim.sh` 要先 uninstall 再 install 才會更新。Homebrew 的 gh 用 `brew unlink` 讓位（gh 的 man page 與 shell 補全會暫時不見，uninstall 時 `brew link` 回來），gh 本身照樣隨 `brew upgrade` 更新。記錄只有誰、什麼、何時，沒有耗時與結束碼。

看到誤擋就把那條指令加進 `tests/hooktest.sh` 當 allow 案例再修 hook；看到漏擋就加 DENY 案例。gh-wait 的行為測在 `tests/gh-wait-test.sh`（假的 gh 放 PATH 最前面）。
