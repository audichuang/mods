# audi-mods

Personal Claude Code plugins and mods.

| Plugin | What it does |
|---|---|
| `gh-quota` | Keeps agents from burning the shared GitHub API quota: `gh-wait` (waits on CI with ETags), a hook that blocks `gh` polling loops and anonymous `curl`, and a skill on how to wait |
| `gh-quota-meter` | Shows the remaining GitHub API quota in the status line, warns once below 1000 |
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
