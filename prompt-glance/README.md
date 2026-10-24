# prompt-glance

A two-row HUD for Claude Code, drawn right above the prompt. One glance tells you which model you are on, where you are, how full the context and your plan windows are, whether the prompt cache is still warm, and what Claude has been doing.

```
Opus 5.5  ~/Project/app  git:(main*) ↑1      Turn $0.42 +0.8%  Session $3.10  ● Cache 1h ████████████ 58m  hit 99.6%  misses 1
Context ███▌████████ 22%   5h █▎██████████ 10%   Week ▌███████████ 4%   GH ██▍█████████ 20%      Tools Bash×20  Edit×3  Skills tdd
```

It is a Claude Code **mod** (a plugin of function hooks), not a status line command: it redraws every second from the engine's own figures, so the cache countdown is live and a `/model` switch shows at once.

## What you see

**Row one: who and where, then what it costs and the cache**

- **Model**, coloured by family (Opus amber, Sonnet blue, Haiku green, Fable lavender).
- **Path**, with `~` for home, shortened from the left when the row is tight.
- **Git**, as `git:(branch)`: a yellow `*` when the tree is dirty, `↑n` / `↓n` against upstream.
- **Turn** and **Session**: what the current turn has spent so far (from the prompt you sent to the end of the answer, every request and tool call in between) and its share of the 5-hour window (`+0.8%`: grey under 1%, yellow to 3%, red past it), then the session's total. The figures stay after the turn ends until you send the next prompt.
- **Cache**: a dot, the lifetime in use (`5m` or `1h`), a bar that drains as it runs out and the time left, all green, then yellow, then red as it lapses; once it has lapsed, `○ Cache cold`. Then `hit`, the session's hit rate (every main-loop request's cache reads over all its prompt tokens; the last request alone sits near 100% in any long conversation, and 99.5% never rounds up to 100%), and `misses n` when some requests wrote the prefix again instead of reading it. Words appear only when there is something to do: `expiring · send a message`; once lapsed, `next message re-caches 82k tokens`, with `· /compact first` on a large context; `missed`; `not cached`; `caching off`; and `waiting for first request` before the first one.

**Row two: how much is used, then the activity**

- **Context**, **5h**, **Week** and **GH** as solid bars that warm from green to red along their length; the last cell fills by eighths, so the bar moves smoothly. The percentage takes the colour of its level, and a plan window past 50% also shows when it resets (`↻3h`).

  | Level | green | lime | yellow | orange | red |
  | --- | --- | --- | --- | --- | --- |
  | Context | < 30% | 30-50% | 50-65% | 65-80% | ≥ 80% |
  | 5h / Week | < 40% | 40-60% | 60-75% | 75-90% | ≥ 90% |

  The context window turns sooner: a fuller context degrades answers and nears auto-compact well before a plan window runs out.
- **GH** is the share of the account's GitHub REST quota used (5000 an hour), read with `gh api rate_limit` every two minutes in an interactive session (that call costs none of the quota). `未登入` when gh has no token (never logged in, or the anonymous 60 an SSH session without the keychain gets). When a check fails the last reading stays with a grey `?`, and goes once its hour has reset. No gh, no GH gauge.
- **Tools** the main loop ran, most used first (MCP tools by their last name segment), with a red `✗n` when some failed; **Skills** loaded, by name.

**On a narrow terminal** the two rows fold into a stack with aligned labels, and the activity is left out so the essentials keep room around them:

```
Opus 5.5  ~/Project/app
● Cache   1h ████████████ 58m  hit 99.6%
Turn    $0.42 +0.8%  Session $3.10
Context ███▌████████ 22%
5h      █▎██████████ 10%  Week    ▌███████████ 4%
```

### What the dollars count

The dollars are Claude Code's own ledger, the figure `/cost` shows: every request priced by its four token counts, uncached input at the base rate, cache reads at about 0.1x, cache writes at 1.25x (5-minute) or 2x (1-hour), and output. So a well-kept cache shows up as a cheap turn, and a lapsed one on a large context as an expensive one. Two things to keep in mind:

- On a Claude subscription the dollars are what the same work would cost at API prices, not a bill; the window share (`+0.8%`) is what actually counts against you.
- The dollars include subagents (the ledger is the session's); the cache meter does not (subagents have prefixes of their own). A turn that fans out to subagents can cost more while the cache figure stays high.
- The plan windows report one decimal after each response, so a short turn can read `+0.0%`.

`/cache` opens a pane with a per-turn table of cache reads, writes and uncached tokens.

## How the countdown works

From Anthropic's [prompt caching](https://platform.claude.com/docs/en/build-with-claude/prompt-caching) documentation:

- The cache lives **5 minutes** by default, **1 hour** when asked for.
- Every request that reads the cache **refreshes** it at no extra cost, so a conversation that keeps talking keeps the 5-minute cache warm.
- The lifetime is counted from the **start** of the request that wrote or read the entry; generation time counts against it.
- A prompt is `input_tokens` (uncached remainder) + `cache_read_input_tokens` + `cache_creation_input_tokens`.
- Writes cost 1.25x base input for 5 minutes and 2x for 1 hour; reads cost about 0.1x (less on some models). The expensive moment is an expired cache on a large context, which is when this mod suggests `/compact`.
- `/clear` starts a new conversation in the same process, so the meter and the `/cache` table start over with it. A change in the prefix (model, effort or thinking settings, tool set, system prompt, `CLAUDE.md`) makes the next request write instead of read. The mod names the cause when it sees a miss: model changed, the cache had lapsed, or the prefix changed.

## Which lifetime your account gets

The mod follows Claude Code's own rules ([prompt caching: cache lifetime](https://code.claude.com/docs/en/prompt-caching#cache-lifetime), Claude Code 2.1.242 or later). For the main conversation the TTL is the first match of:

| # | Source | Result |
| --- | --- | --- |
| 1 | the mod's `ttl` option (`5m` / `1h`) | what you set |
| 2 | `FORCE_PROMPT_CACHING_5M=1` | 5 minutes |
| 3 | `CLAUDE_CODE_PROMPT_CACHE_TTL` | `5m` or `1h` |
| 4 | the `promptCacheTtl` setting (local, project or user settings file) | `5m` or `1h` |
| 5 | `ENABLE_PROMPT_CACHING_1H=1` | 1 hour |
| 6 | the account | **1 hour on a Claude subscription within its plan usage**; 5 minutes on usage credits, an API key or a cloud provider |

The account comes from the rate-limit windows the last response reported: a `five_hour` or `seven_day` window means a subscription, and one at 100% means requests now draw on usage credits. An API key or a cloud provider reports no such window, and before the first response nothing is known, so the mod starts from 5 minutes there. Managed settings are not readable from a mod.

On top of that the mod watches the traffic, which beats rows 2 to 6: a request that **hits** the cache more than 5 minutes after the previous one proves the 1-hour lifetime (a later miss does not undo it, since a changed prefix looks the same), and a **miss** 5 to 60 minutes after the previous request, with the same model and a prompt that did not shrink, says the entry lapsed, so 5 minutes (a later hit overrules it). That covers what the mod cannot see: managed settings, a gateway that rewrites the TTL, or a subscription that ran out of plan usage mid-session. The pane header names the source in use.

Why the mod infers instead of reading it: the API names the TTL of each write (`cache_creation.ephemeral_5m_input_tokens` / `ephemeral_1h_input_tokens`) and Claude Code's status line exposes it as `prompt_cache.ttl`, but the mod API passes on only the four token counts. To check by hand, `claude -p "hello" --output-format json` and read `usage.cache_creation`.

Other switches read from the environment at session start:

| Variable | Effect on the meter |
| --- | --- |
| `DISABLE_PROMPT_CACHING=1` (and `_HAIKU`, `_SONNET`, `_OPUS`) | the band says caching is off for that model |

## What it hooks

- `turn.start`: notes the session's cost and the plan windows as last read, so the turn's share can show (the main loop's turns only: a subagent's runs inside one)
- `turn.step`: each main-loop request's cache usage (subagents have their own prefixes and are left out)
- `tool.call`: counts tools and skills, and whether a call failed
- `session.end`: a `/clear` or a resume starts the meter, the `/cache` table and the activity over, and the clock runs on
- `$.clock.every(1000)`: the countdown and the model; context and plan windows are re-read every 5 seconds, git status every 30, the GitHub quota every 2 minutes
- `$.process.run`: `git --no-optional-locks status --porcelain -b` (so it never takes the index lock from your own git commands) and `gh api rate_limit`, both in the background: no hook waits on them, the HUD draws the last reading and redraws when a new one lands
- `ui.render` on `AbovePrompt` (the HUD), on `PromptHint` (the HUD under the prompt, with `position: below`) and on `Pane` (`/cache`); the HUD gives way to a survey and to the open `/cache` pane
- `$.ui.toast`: at the warning threshold (60 s by default) and at 10, 3, 2 and 1 seconds left, for prompts of 20k tokens or more

## Install

Requires Claude Code 2.1.287 or later (mods on by default).

```
/plugin marketplace add audichuang/mods
/plugin install prompt-glance@audi-mods
```

It loads as `prompt-glance@audi-mods` in every session. To try it for one session instead: `claude --plugin-dir /path/to/prompt-glance`.

It does not replace your `statusLine` setting; if you used a status line for the same figures, remove it from `~/.claude/settings.json` to avoid showing them twice.

To check a change, run the repository's gate from its root: `bash scripts/check.sh` validates every plugin (`claude plugin validate --strict`), runs this mod's tests (`claude plugin test prompt-glance`) and type-checks it.

## Options

Set them in the `/plugin` menu (prompt-glance's options), or in user settings (`~/.claude/settings.json`), `--settings <file>` or managed settings:

```json
{ "pluginConfigs": { "prompt-glance@audi-mods": { "options": { "ttl": "auto" } } } }
```

```
  ttl: string               "auto" | "5m" | "1h" (default auto)
  position: string          "above" | "below": the band over the prompt, or the hint line under it, right of the mode label (default above)
  warnSeconds: number       countdown threshold for the warning state and the first toast (default 60)
  compactAtTokens: number   prompt size from which an expired cache suggests /compact (default 100000)
  band: boolean             the HUD above the prompt (default true)
  status: boolean           also a short entry under the prompt, "cache 98% · 3:41" (default false)
  toast: boolean            toasts as the cache lapses (default true)
```

## Credits

Grew out of [`prompt-cache-control`](https://github.com/davila7/claude-code-templates/tree/main/cli-tool/components/mods/observability/prompt-cache-control) from [claude-code-templates](https://github.com/davila7/claude-code-templates) by Daniel (San) Ávila, MIT licensed: the cache accounting, TTL rules and `/cache` pane come from there. The HUD layout borrows its contents from [claude-hud](https://github.com/jarrodwatts/claude-hud).

## License

MIT
