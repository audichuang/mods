# audi-mods

Personal Claude Code plugins and mods.

| Plugin | What it does |
|---|---|
| `gh-quota` | Keeps agents from burning the shared GitHub API quota: `gh-wait` (waits on CI with ETags), a hook that blocks `gh` polling loops and anonymous `curl`, and a skill on how to wait |
| `gh-quota-meter` | Logs the GitHub API quota (REST/GraphQL) to meter.log every 2 min and toasts once per reset window when it drops below 1000; the status-line entry is opt-in (`status` option), and prompt-glance's HUD shows the quota by default |
| `prompt-glance` | Two-row HUD above the prompt: model, branch, context and plan-window gauges, prompt-cache hit rate and countdown |
| `zh-steady` | Nudges the model back to Traditional Chinese when a step drifts into English |

## Install

```
/plugin marketplace add audichuang/mods
/plugin install gh-quota --marketplace audichuang/mods
/plugin install gh-quota-meter --marketplace audichuang/mods
/plugin install prompt-glance --marketplace audichuang/mods
/plugin install zh-steady --marketplace audichuang/mods
```
