/**
 * prompt-glance — Claude Mod (grew out of prompt-glance from davila7/claude-code-templates)
 *
 * A prompt-cache meter for Claude Code. Every main-loop request reports how
 * many prompt tokens the cache served (`cache_read_input_tokens`), wrote
 * (`cache_creation_input_tokens`) and sent uncached (`input_tokens`); this mod
 * keeps those per request and per turn, counts down to the moment the cache
 * lapses, and says what to do about it: keep going, /compact or /clear.
 *
 *   - `turn.step` reads each main-loop request's usage (subagents have their
 *     own prefixes and are left out)
 *   - `$.clock.every(1000)` redraws the countdown, and only while its text
 *     changes: an idle, expired session costs nothing
 *   - a row above the prompt (the AbovePrompt component), an optional status
 *     line entry, and `/cache`, a pane with one row per turn
 *
 * The lifetime is counted from the start of the request that last wrote or read
 * the cache, as Anthropic documents it. Which lifetime Claude Code asked for
 * follows its documented rules (see decideTtl in ./cache.ts): FORCE_PROMPT_CACHING_5M,
 * CLAUDE_CODE_PROMPT_CACHE_TTL, the promptCacheTtl setting, ENABLE_PROMPT_CACHING_1H,
 * then the account (1 hour on a Claude subscription, 5 minutes otherwise). The
 * API names the TTL of a write but the mod API passes on only the token counts,
 * so while the lifetime is the account's default the mod also watches the gaps
 * between requests (a hit after more than 5 minutes proves 1 hour; see
 * observeTtl), and drops what it saw when that default changes. `ttl: "5m" | "1h"`,
 * the environment variables and the setting pin it.
 *
 * Needs Claude Code >= 2.1.287.
 *
 * Options (the /plugin menu, or pluginConfigs["prompt-glance@audi-mods"].options):
 *   ttl: "auto" | "5m" | "1h"   cache lifetime (default auto)
 *   position: "above" | "below" the band over the prompt, or the hint line under it (default above)
 *   warnSeconds: number         countdown threshold for the warning (default 60)
 *   compactAtTokens: number     prompt size that makes an expired cache suggest /compact (default 100000)
 *   band: boolean               row above the prompt (default true)
 *   status: boolean             entry under the prompt (default false)
 *   toast: boolean              toasts near expiry: at warnSeconds, then 10, 3, 2 and 1 s (default true)
 */
import type { EngineInterface, Register, ResolveInput } from 'claude-code'
import {
  advise,
  COUNTDOWN_MARKS,
  byTurn,
  fit,
  fmtClock,
  fmtTokens,
  hitRatio,
  isCachingDisabled,
  accountOf,
  cells,
  addToTotals,
  emptyTotals,
  totalsHit,
  decideTtl,
  isAccountDefault,
  observeTtl,
  lifeColor,
  lifeRatio,
  nextToastMark,
  positive,
  promptTokens,
  remainingMs,
  rowRatio,
  segments,
} from './cache'
import type { Account, Advice, BandPart, BandSeg, CacheEnv, Sample, SessionTotals, Ttl } from './cache'
import { deltaColor, fmtPct, fmtShort, fmtUsd, heat, turnSpend, heatGauge, lineGauge, modelColor, parseGitStatus, parseRateLimit, prettyModel, SCALE, shortAdvice, shortPath, topTools } from './hud'
import type { GhQuota, ToolTally } from './hud'

const PANE = 'cache'
const COMMAND = 'cache'
const KEEP = 200
// below this a lapsed cache costs too little to interrupt anyone about
const TOAST_MIN_TOKENS = 20_000

// the lifetime Claude Code asks for, and why, before any request timing says otherwise
let baseTtl: Ttl = '5m'
let envSource = 'default'
// whether that came from the account's default, the only lifetime request timing may overrule
let inferable = true
// the ttl option, as the config menu set it
let ttlOption: unknown
let setting: Ttl | undefined
let account: Account = 'other'
let env: CacheEnv = {}
let timer: { cancel: () => void } | undefined
let isPaneOpen = false

// the HUD's session figures, read off the engine every few seconds and drawn from here
type Window = { pct: number; resetsAt?: number }
let model = ''
let cwd = ''
let home: string | undefined
let git: { branch: string; dirty: boolean; ahead: number; behind: number } | undefined
let ctxPct: number | undefined
// each usage read is numbered (asked); one answered after a newer one has landed (applied) is dropped,
// so a slow read cannot undo it
const usageReads = { asked: 0, applied: 0 }
let five: Window | undefined
let week: Window | undefined
// git status: one running at a time (busy), and when the last one started
const gitReads = { busy: false, startedAt: 0 }
// the account's GitHub REST quota (rate_limit itself costs none of it); stale: the last check failed,
// so the reading on show is an old one
let ghReading: { quota?: GhQuota; stale: boolean } = { stale: false }
let ghBin: string | null | undefined
const GH_EVERY_TICKS = 120
const GH_JQ = '[.resources.core.remaining, .resources.core.limit, .resources.core.reset] | @tsv'
// $.process.run takes no shell, and the Claude process's PATH may lack Homebrew's bin
const GH_PATHS = ['gh', '/opt/homebrew/bin/gh', '/home/linuxbrew/.linuxbrew/bin/gh', '/usr/local/bin/gh', '/usr/bin/gh'] as const
// one line per change of why the HUD is or isn't drawn, newest HUD_LOG_MAX kept
const HUD_LOG = '.local/state/prompt-glance/hud.log'
const HUD_LOG_MAX = 500
let lastNote = ''
// a plan window's reset time shows only from here up
const LOUD = 50
// cells between the band's parts: room to breathe
const GAP = 2
// the /cache pane's rows drawn around the turn table, so the table takes what is left:
// always the title 1, the clock 2, the advice 2, the table's head 2 and the footer 6
const PANE_FIXED_ROWS = 1 + 2 + 2 + 2 + 6
// the life bar under the clock, while it counts down
const PANE_LIFE_BAR_ROWS = 1
// once a request has landed: its model line under the advice, and the stack 3
const PANE_LAST_REQUEST_ROWS = 1 + 3
// the table shows at least this many turns, however short the pane
const PANE_MIN_TABLE_ROWS = 3

/** What belongs to one conversation: /clear and a resume start it over, the account's figures stay. */
type Conversation = {
  // the last KEEP main-loop requests
  samples: Sample[]
  // the whole conversation's reads, writes, uncached input and misses, beyond the KEEP samples
  totals: SessionTotals
  // each turn's number in the conversation, counted apart from the samples
  turnNo: Map<string, number>
  // the lifetime in force and why: what the requests' timing showed (observed), else baseTtl
  ttl: Ttl
  ttlSource: string
  observed: Ttl | undefined
  // when the lifetime Claude Code asks for last changed: the start of the latest request before it. An entry that
  // request (or an earlier one) wrote lives by the old lifetime, so a hit on it says nothing about the new one
  ttlChangedAfter: number
  // what the clock last drew, so it redraws only on a change
  lastKey: string
  // the countdown toasts: the request whose cache entry they count down, and the mark last fired
  toast: { startedAt: number; level: number }
  // the tools the main loop ran, and the skills it loaded by name, with how often
  tally: ToolTally
  skills: Map<string, number>
  // what the conversation has cost so far, and the figures at the start of the current turn, so the turn's share shows
  costUsd: number | undefined
  turnBase: { usd?: number; five?: number; week?: number } | undefined
}

const startConversation = (): Conversation => ({
  samples: [],
  totals: emptyTotals(),
  turnNo: new Map(),
  ttl: baseTtl,
  ttlSource: envSource,
  observed: undefined,
  ttlChangedAfter: -Infinity,
  lastKey: '',
  toast: { startedAt: 0, level: Infinity },
  tally: new Map(),
  skills: new Map(),
  costUsd: undefined,
  turnBase: undefined,
})

let conv = startConversation()

/**
 * Re-reads the session's figures (git, usage, the model), re-picks the cache
 * lifetime from them and redraws. No hook awaits it: the HUD draws the latest
 * reading and redraws when a new one lands. git status runs apart, one at a
 * time, so a slow or locked repo holds back neither a hook nor the other figures.
 */
async function rereadAndRedraw($: EngineInterface, gitNow = false): Promise<void> {
  readGitStatus($, gitNow)
  await readUsageFigures($)
  model = prettyModel(await $.session.model().catch(() => model))
  recomputeTtl()
  $.ui.invalidate('ui.render')
}

/** Cost, context and the plan windows, off the engine (no git): quick enough for turn.start to wait on. */
async function readUsageFigures($: EngineInterface) {
  const n = ++usageReads.asked
  const u = await $.session.usage().catch(() => undefined)
  if (u && n > usageReads.applied) {
    usageReads.applied = n
    ctxPct = u.context.percent
    conv.costUsd = u.cost?.usd
    const win = (kind: string): Window | undefined => {
      const r = u.rateLimits.find(l => l.kind === kind)
      return r ? { pct: r.percentUsed, resetsAt: r.resetsAt ? Date.parse(r.resetsAt) : undefined } : undefined
    }
    five = win('five_hour')
    week = win('seven_day')
    // the account can change under a session: a subscription running out of plan usage moves to usage credits
    account = accountOf(u.rateLimits)
  }
}

/** git status in the background, one at a time and at most every 30 s unless `force`d. */
function readGitStatus($: EngineInterface, force: boolean) {
  if (gitReads.busy || (!force && Date.now() - gitReads.startedAt <= 30_000)) return
  gitReads.busy = true
  gitReads.startedAt = Date.now()
  // --no-optional-locks: a status run in the background must not take index.lock from the agent's own git commands
  void $.process
    .run(['git', '--no-optional-locks', 'status', '--porcelain', '-b'], { timeoutMs: 10_000 })
    .then(
      r => {
        git = r.exitCode === 0 ? parseGitStatus(r.stdout) : undefined
        $.ui.invalidate('ui.render')
      },
      // timed out or could not start: the branch last read stays
      () => undefined,
    )
    .finally(() => {
      gitReads.busy = false
    })
}

/**
 * Which lifetime Claude Code asks for now, from the option, the environment, the setting and the account.
 * A change of it (a subscription out of plan usage moving to usage credits) outdates what the traffic showed.
 */
function recomputeTtl() {
  const choice = decideTtl(ttlOption, env, setting, account)
  if (choice.ttl !== baseTtl || choice.source !== envSource) {
    conv.observed = undefined
    conv.ttlChangedAfter = conv.samples[conv.samples.length - 1]?.startedAt ?? -Infinity
  }
  baseTtl = choice.ttl
  envSource = choice.source
  inferable = isAccountDefault(choice)
  if (conv.observed === undefined) {
    conv.ttl = baseTtl
    conv.ttlSource = envSource
  }
}

/** A conversation of its own: its cache, its requests, its turns and its activity start over. */
function newConversation() {
  conv = startConversation()
  // a usage reading still on its way is the old conversation's
  usageReads.applied = usageReads.asked
}

/** The account's GitHub REST quota, through gh: found once on the usual paths, then asked each time. */
async function readGhQuota($: EngineInterface) {
  if (ghBin === undefined) {
    ghBin = null
    for (const bin of GH_PATHS) {
      const ran = await $.process.run([bin, '--version'], { timeoutMs: 5_000 }).catch(() => undefined)
      if (ran?.exitCode === 0) {
        ghBin = bin
        break
      }
    }
  }
  if (ghBin === null) return
  const ran = await $.process.run([ghBin, 'api', 'rate_limit', '--jq', GH_JQ], { timeoutMs: 15_000 }).catch(() => undefined)
  // exit 4, or gh asking for `gh auth login`: no token at all, which the gauge says as it does for the anonymous 60
  const noLogin = ran !== undefined && (ran.exitCode === 4 || /gh auth login/.test(`${ran.stdout}\n${ran.stderr}`))
  const quota: GhQuota | undefined = ran?.exitCode === 0 ? parseRateLimit(ran.stdout) : noLogin ? { anon: true } : undefined
  const old = ghReading.quota
  if (quota) ghReading = { quota, stale: false }
  else if (old) {
    // a failed or timed-out check keeps the last reading, marked as old, until its window resets
    ghReading = { quota: !old.anon && Date.now() >= old.resetsAt ? undefined : old, stale: true }
  }
}

/** Appends `event` to hud.log when it differs from the last line written; never throws. */
async function note($: EngineInterface, event: string) {
  if (event === lastNote || home === undefined) return
  lastNote = event
  const path = `${home}/${HUD_LOG}`
  const before = await $.fs.read(path).catch(() => '')
  const kept = [...before.split('\n').filter(l => l !== ''), `${new Date().toISOString()}\t${event}`].slice(-HUD_LOG_MAX)
  await $.fs.write(path, kept.join('\n') + '\n').catch(() => undefined)
}

type Policy = { warnMs: number; compactAtTokens: number }

// cells a group of parts takes, GAP between them
const groupCells = (parts: readonly BandPart[]) => parts.reduce((n, p) => n + cells(p.text), 0) + Math.max(0, parts.length - 1) * GAP

/** Whether a `[left, right]` row fits in `width`, its two groups at least GAP apart. */
function fitsRow([l, r]: [BandPart[], BandPart[]], width: number): boolean {
  return groupCells(l) + (r.length ? GAP + groupCells(r) : 0) <= width
}

// stacked rows pad their labels to the longest, so the gauges line up
const LABEL_PAD = 'Context'.length

function current(policy: Policy, now: number) {
  const last = conv.samples[conv.samples.length - 1]
  const prev = conv.samples[conv.samples.length - 2]
  const disabled = last ? isCachingDisabled(last.model, env) : isCachingDisabled('', env)
  const advice: Advice = advise(last, prev, { ttl: conv.ttl, ...policy }, now, disabled)
  const left = last ? remainingMs(last, conv.ttl, now) : 0
  return { last, advice, left }
}

const COLOR: Record<Advice['kind'], string | undefined> = {
  warm: 'green',
  soon: 'yellow',
  expired: 'red',
  miss: 'red',
  off: undefined,
  cold: undefined,
  uncached: undefined,
}

function shortLine(policy: Policy, now: number): string {
  const { last, advice, left } = current(policy, now)
  if (!last || advice.kind === 'off') return `cache: ${advice.text}`
  const clock = left > 0 ? ` · ${fmtClock(left)}` : ''
  return `cache ${Math.round(hitRatio(last) * 100)}%${clock}`
}

// the promptCacheTtl setting as the engine merges it (policy, --settings, CLAUDE_CONFIG_DIR's user file, project, local)
async function readSetting($: EngineInterface): Promise<Ttl | undefined> {
  const value = await $.settings.read({ key: 'promptCacheTtl' }).catch(() => undefined)
  return value === '5m' || value === '1h' ? value : undefined
}

// The HUD's rows for a site `columns` wide, built from that site's element table.
function drawHud($: EngineInterface, e: ResolveInput, columns: number, policy: Policy) {
  const now = Date.now()
  const { last, advice, left } = current(policy, now)
  const { Box, Text } = $.ui.resolve(e)
  const part = (key: string, segs: BandSeg[]): BandPart => ({ key, text: segs.map(g => g.text).join(''), segs })
  const label = (text: string, pad = 0): BandSeg => ({ text: `${text.padEnd(pad)} `, color: 'gray' })

  // row one, left: who and where
  const who = part('model', [{ text: model || 'Claude', color: modelColor(model), bold: true }])
  const where = (levels?: number) => part('path', [{ text: shortPath(cwd, home, levels), color: 'blue' }])
  const branch: BandPart[] = git
    ? [
        part('git', [
          { text: 'git:(', color: 'gray' },
          { text: git.branch, color: 'cyan' },
          ...(git.dirty ? [{ text: '*', color: 'yellow', bold: true }] : []),
          { text: ')', color: 'gray' },
          ...(git.ahead ? [{ text: ` ↑${git.ahead}`, color: 'green' }] : []),
          ...(git.behind ? [{ text: ` ↓${git.behind}`, color: 'red' }] : []),
        ]),
      ]
    : []

  // row one, right: the cache, its hit rate and how long it stays warm
  const state = shortAdvice(advice, last ? fmtTokens(promptTokens(last)) : undefined)
  // the session's hit rate and misses: the last request alone sits near 100% in any long conversation
  const sessionHitRatio = totalsHit(conv.totals)
  const misses = conv.totals.misses
  const ratio = sessionHitRatio
  const counting = !!last && advice.kind !== 'uncached' && advice.kind !== 'off'
  const lifeC = counting ? (left > 0 ? lifeColor(left, conv.ttl, policy.warnMs) : 'red') : undefined
  const hitC = ratio >= 0.8 ? 'green' : ratio >= 0.4 ? 'yellow' : 'red'
  // ● Cache 1h ████████████ 59m  hit 76%  misses 1   (the dot and the bar drain green, yellow, red; ○ cold once lapsed)
  const cache = (width: number, words = true, pad = 0): BandPart[] => {
    const lapsed = advice.kind === 'expired'
    const dot: BandSeg = counting && !lapsed ? { text: '● ', color: lifeC } : { text: '○ ', color: lapsed ? 'red' : 'gray' }
    const segs: BandSeg[] = [dot, label('Cache', pad)]
    if (lapsed) segs.push({ text: 'cold', color: 'red', bold: true })
    else if (counting) {
      segs.push({ text: `${conv.ttl} `, color: lifeC })
      if (width > 0) segs.push(...lineGauge(lifeRatio(left, conv.ttl), width, lifeC), { text: ' ' })
      segs.push({ text: fmtShort(left), color: lifeC, bold: true })
    }
    if (last) {
      segs.push({ text: '  hit ', color: 'gray' }, { text: fmtPct(sessionHitRatio), color: hitC, bold: true })
      if (misses > 0) segs.push({ text: '  misses ', color: 'gray' }, { text: String(misses), color: misses > 2 ? 'red' : 'yellow', bold: true })
    }
    if (state.text && (words || !last)) segs.push({ text: `  ${state.text}`, color: COLOR[advice.kind] ?? 'gray', bold: advice.kind !== 'cold' })
    return [part('cache', segs)]
  }

  // row two, left: the context window and the plan windows
  const meter = (key: string, name: string, pct: number | undefined, width: number, scale: readonly number[], resetsAt?: number, pad = 0): BandPart[] => {
    if (pct === undefined) return []
    const color = heat(pct, scale)
    const reset = pct >= LOUD && resetsAt ? [{ text: ` ↻${fmtShort(resetsAt - now)}`, color: 'gray' }] : []
    return [part(key, [label(name, pad), ...heatGauge(pct, width, scale), { text: ` ${Math.round(pct)}%`, color, bold: pct >= (scale[2] ?? Infinity) }, ...reset])]
  }
  // GitHub's REST quota used, like the plan windows; no token says so instead of showing the anonymous 60
  // an old reading (the last check failed) carries a grey ?, and says nothing once its window has reset
  const gh = (width: number, pad = 0): BandPart[] => {
    const { quota, stale } = ghReading
    if (!quota) return []
    if (quota.anon) return [part('gh', [label('GH', pad), { text: '未登入', color: 'gray' }])]
    if (!stale) return meter('gh', 'GH', quota.pct, width, SCALE.window, quota.resetsAt, pad)
    if (now >= quota.resetsAt) return []
    return meter('gh', 'GH', quota.pct, width, SCALE.window, undefined, pad).map(p => part(p.key, [...(p.segs ?? []), { text: ' ?', color: 'gray' }]))
  }
  const gauges = (width: number, withWeek = true) => [
    ...meter('ctx', 'Context', ctxPct, width, SCALE.context),
    ...meter('5h', '5h', five?.pct, width, SCALE.window, five?.resetsAt),
    ...(withWeek ? meter('7d', 'Week', week?.pct, width, SCALE.window, week?.resetsAt) : []),
    ...gh(width),
  ]

  // row two, right: the tools the main loop ran
  // the activity: tools by use (skills apart), then the skills by name
  const toolsOnly: ToolTally = new Map([...conv.tally].filter(([name]) => name !== 'Skill'))
  const tools = (n: number, pad = 0): BandPart[] => {
    const list = topTools(toolsOnly, n)
    if (list.length === 0) return []
    const failed = [...toolsOnly.values()].reduce((sum, c) => sum + c.failed, 0)
    return [
      part('tools', [
        label('Tools', pad),
        ...list.flatMap(([name, ok, bad], i) => [{ text: `${i ? '  ' : ''}${name}` }, { text: `×${ok + bad}`, color: 'gray' }]),
        ...(failed > 0 ? [{ text: `  ✗${failed}`, color: 'red', bold: true }] : []),
      ]),
    ]
  }
  const skillList = (n: number, pad = 0): BandPart[] => {
    const list = [...conv.skills].sort((a, b) => b[1] - a[1]).slice(0, n)
    if (list.length === 0) return []
    return [
      part('skills', [
        label('Skills', pad),
        ...list.flatMap(([name, count], i) => [{ text: `${i ? '  ' : ''}${name}`, color: 'magenta' }, ...(count > 1 ? [{ text: `×${count}`, color: 'gray' }] : [])]),
        ...(conv.skills.size > n ? [{ text: `  +${conv.skills.size - n}`, color: 'gray' }] : []),
      ]),
    ]
  }
  // as many tools and skills as fit, each on a row of its own
  const activityRows = (pad: number): [BandPart[], BandPart[]][] => {
    const out: [BandPart[], BandPart[]][] = []
    for (const make of [tools, skillList]) {
      const fit = [6, 4, 3, 2, 1].map(n => make(n, pad)).find(p => p.length === 0 || fitsRow([p, []], columns))
      if (fit && fit.length) out.push([fit, []])
    }
    return out
  }

  // what the current (or last) turn spent: dollars, and its share of the 5-hour window; the session's total beside it
  const spent = turnSpend(conv.turnBase, conv.costUsd, five?.pct, week?.pct)
  const spend = (withSession: boolean, pad = 0): BandPart[] => {
    if (!spent) return []
    const segs: BandSeg[] = [label('Turn', pad)]
    if (spent.usd !== undefined) segs.push({ text: fmtUsd(spent.usd), color: '#c0caf5', bold: true })
    if (spent.five !== undefined) segs.push({ text: `${segs.length > 1 ? ' ' : ''}+${spent.five.toFixed(1)}%`, color: deltaColor(spent.five) })
    if (segs.length === 1) return []
    if (withSession && conv.costUsd !== undefined) segs.push({ text: '  ' }, label('Session'), { text: fmtUsd(conv.costUsd), color: 'gray' })
    return [part('spend', segs)]
  }

  // wide: two rows, a left and a right group each, when nothing has to go
  const wideTop: [BandPart[], BandPart[]][] = [
    [[who, where(), ...branch], [...spend(true), ...cache(12)]],
    [[who, where(3), ...branch], [...spend(true), ...cache(12)]],
    [[who, where(1), ...branch], [...spend(false), ...cache(12)]],
    [[who, where(1), ...branch], [...spend(false), ...cache(10)]],
    [[who, where(1), ...branch], cache(10)],
  ]
  // the activity rides at the right of the gauges when it fits there whole, else takes rows of its own
  const activity = [...tools(4), ...skillList(2)]
  const wideBottom: [BandPart[], BandPart[]][] = [
    [gauges(12), activity],
    [gauges(12), []],
    [gauges(10), activity],
    [gauges(10), []],
  ]
  let rows: [BandPart[], BandPart[]][]
  const top = wideTop.find(v => fitsRow(v, columns))
  const bottom = wideBottom.find(v => fitsRow(v, columns))
  if (top && bottom) {
    rows = [top, bottom]
    if (bottom[1].length === 0) rows.push(...activityRows(0))
  } else {
    // narrow: stack instead of dropping, labels padded so the gauges line up
    rows = []
    const head = [[who, where(), ...branch], [who, where(3), ...branch], [who, where(1), ...branch]].find(l => fitsRow([l, []], columns))
    if (head) rows.push([head, []])
    else rows.push([[who], []], [[where(1), ...branch], []])
    const pad = LABEL_PAD
    const cacheRow = [cache(12, true, pad), cache(10, true, pad), cache(8, true, pad), cache(6, false, pad)].find(c => fitsRow([c, []], columns)) ?? cache(0, false, pad)
    rows.push([cacheRow, []])
    const spendRow = [spend(true, pad), spend(false, pad)].find(p => p.length && fitsRow([p, []], columns))
    if (spendRow) rows.push([spendRow, []])
    const width = [12, 10, 8].find(w => fitsRow([meter('ctx', 'Context', 100, w, SCALE.context, undefined, pad), []], columns)) ?? 6
    let line: BandPart[] = []
    for (const g of [
      ...meter('ctx', 'Context', ctxPct, width, SCALE.context, undefined, pad),
      ...meter('5h', '5h', five?.pct, width, SCALE.window, five?.resetsAt, pad),
      ...meter('7d', 'Week', week?.pct, width, SCALE.window, week?.resetsAt, pad),
      ...gh(width, pad),
    ]) {
      if (line.length && !fitsRow([[...line, g], []], columns)) {
        rows.push([line, []])
        line = []
      }
      line.push(g)
    }
    if (line.length) rows.push([line, []])
    // too narrow for the activity: the essentials only, with room around them
  }

  const group = (key: string, parts: BandPart[]) => (
    <Box key={key} flexDirection="row" columnGap={GAP} flexShrink={0}>
      {parts.map(p => (
        <Box key={p.key} flexDirection="row" flexShrink={0}>
          {(p.segs ?? [{ text: p.text, color: p.color }]).map((g, j) => (
            <Text key={`${p.key}:${j}`} color={g.color} backgroundColor={g.backgroundColor} bold={g.bold} dimColor={g.dim}>{g.text}</Text>
          ))}
        </Box>
      ))}
    </Box>
  )
  const row = (key: string, [l, r]: [BandPart[], BandPart[]]) => (
    <Box key={key} flexDirection="row" flexWrap="nowrap">
      {group(`${key}:l`, l)}
      {r.length ? <Box key={`${key}:gap`} flexGrow={1} minWidth={GAP} /> : null}
      {r.length ? group(`${key}:r`, r) : null}
    </Box>
  )
  return { Box, Text, rows: rows.map((r, i) => row(`row${i}`, r)) }
}

export const register: Register = (on, options) => {
  const policy: Policy = {
    warnMs: positive(options.warnSeconds, 60) * 1000,
    compactAtTokens: positive(options.compactAtTokens, 100_000),
  }
  const showBand = options.band !== false
  const showStatus = options.status === true
  const wantToast = options.toast !== false
  // above the prompt unless asked for under it: the hint line sits beside the mode pill, so the HUD lands to its right
  const below = options.position === 'below'

  ttlOption = options.ttl

  on('session.start', async ($, e, next) => {
    const r = await next(e)
    newConversation()
    // a hot reload (/reload-plugins, a config change) starts the module over with the /cache pane still up:
    // the engine's record says whether it is, so the band keeps giving way to it
    const panes = await $.ui.panes().catch(() => undefined)
    if (panes) isPaneOpen = panes.some(p => p.id === PANE)
    const none = () => undefined
    env = {
      enable1h: await $.env.get('ENABLE_PROMPT_CACHING_1H').catch(none),
      force5m: await $.env.get('FORCE_PROMPT_CACHING_5M').catch(none),
      ttlVar: await $.env.get('CLAUDE_CODE_PROMPT_CACHE_TTL').catch(none),
      disableAll: await $.env.get('DISABLE_PROMPT_CACHING').catch(none),
      disableHaiku: await $.env.get('DISABLE_PROMPT_CACHING_HAIKU').catch(none),
      disableSonnet: await $.env.get('DISABLE_PROMPT_CACHING_SONNET').catch(none),
      disableOpus: await $.env.get('DISABLE_PROMPT_CACHING_OPUS').catch(none),
    }
    setting = await readSetting($)
    recomputeTtl()

    await $.command
      .register({
        name: COMMAND,
        description: 'Prompt-cache usage per turn and the time left before it lapses (stop closes)',
        argumentHint: '[stop]',
        immediate: true,
      })
      .catch(err => $.ui.log(`prompt-glance: /${COMMAND} not registered: ${err}`))

    cwd = e.cwd
    home = await $.env.get('HOME').catch(() => undefined)
    // the account (and with it the lifetime) is known once the first reading lands
    void rereadAndRedraw($, true).then(() => $.ui.log(`prompt-glance loaded: ${conv.ttl} cache (${conv.ttlSource}), /${COMMAND} opens the table`, { to: 'debug' }))
    void note($, `start ${e.isInteractive ? 'interactive' : 'headless'} ${below ? 'below' : 'above'}`)
    if (e.isInteractive) void readGhQuota($).then(() => $.ui.invalidate('ui.render'))

    let ticks = 0
    timer?.cancel()
    timer = $.clock.every(1000, () => {
      if (e.isInteractive && ticks % GH_EVERY_TICKS === GH_EVERY_TICKS - 1) void readGhQuota($).then(() => $.ui.invalidate('ui.render'))
      if (++ticks % 5 === 0) void rereadAndRedraw($)
      // the model every second: a /model switch shows at once, not on the next request
      else
        void $.session
          .model()
          .then(m => {
            const pretty = prettyModel(m)
            if (pretty !== model) {
              model = pretty
              $.ui.invalidate('ui.render')
            }
          })
          .catch(() => undefined)
      const now = Date.now()
      const { last, advice, left } = current(policy, now)
      const key = `${advice.kind}|${advice.text}|${left > 0 ? fmtClock(left) : ''}`
      if (key !== conv.lastKey) {
        conv.lastKey = key
        if (showStatus) $.ui.status(shortLine(policy, now))
        $.ui.invalidate('ui.render')
      }
      if (wantToast && last && left > 0 && promptTokens(last) >= TOAST_MIN_TOKENS) {
        if (conv.toast.startedAt !== last.startedAt) {
          conv.toast.startedAt = last.startedAt
          conv.toast.level = Infinity
        }
        // the first toast comes at warnSeconds, then 10, 3, 2 and 1 seconds; a late tick skips to the newest one
        const secs = Math.ceil(left / 1000)
        const mark = nextToastMark(secs, policy.warnMs / 1000, conv.toast.level)
        if (mark !== undefined) {
          conv.toast.level = mark
          const tail = secs <= COUNTDOWN_MARKS[0] ? 'send a message now' : `send a message to keep ${fmtTokens(promptTokens(last))} tokens warm`
          $.ui.toast(`cache expires in ${secs >= 60 ? fmtClock(left) : `${secs}s`}: ${tail}`)
        }
      }
    })
    return r
  })

  on('session.end', async ($, e, next) => {
    void note($, `end ${e.reason}`)
    // /clear and a resume carry on in this process with another conversation, and another cache: start over, and
    // keep the clock (no session.start follows). An exit, a logout or the end of a -p run takes the clock with the process.
    const processGoesOn = e.reason !== 'prompt_input_exit' && e.reason !== 'logout' && e.reason !== 'other'
    if (processGoesOn) {
      newConversation()
      $.ui.invalidate('ui.render')
    }
    const r = await next(e)
    // read once the engine is done with the old conversation
    if (processGoesOn) void rereadAndRedraw($)
    return r
  })

  // each main-loop request: what the cache did with it
  // a new turn: remember where cost and the plan windows stand, so the HUD can show what this turn spends
  on('turn.start', async ($, e, next) => {
    // a subagent's turn runs inside the main one, whose baseline stays
    if (e.agentId !== undefined) return next(e)
    // a reading taken now, not the cached one: that may predate the last turn's spending or a /clear.
    // Only the engine's usage call is awaited; git stays in the background
    await readUsageFigures($)
    const r = await next(e)
    conv.turnBase = { usd: conv.costUsd, five: five?.pct, week: week?.pct }
    void rereadAndRedraw($)
    $.ui.invalidate('ui.render')
    return r
  })

  on('turn.step', async function* ($, e, next) {
    if (e.agentId) return yield* next(e)
    const startedAt = await $.clock.now().catch(() => Date.now())
    const r = yield* next(e)
    if (r.usage) {
      const prev = conv.samples[conv.samples.length - 1]
      const cur: Sample = {
        turnId: e.turnId,
        index: e.index,
        model: r.usage.model || e.model,
        startedAt,
        read: r.usage.cache_read_input_tokens,
        write: r.usage.cache_creation_input_tokens,
        fresh: r.usage.input_tokens,
        output: r.usage.output_tokens,
      }
      conv.totals = addToTotals(conv.totals, prev, cur, conv.ttl)
      conv.samples.push(cur)
      if (conv.samples.length > KEEP) conv.samples = conv.samples.slice(-KEEP)
      if (!conv.turnNo.has(e.turnId)) conv.turnNo.set(e.turnId, conv.turnNo.size + 1)
      // the account as last read; the re-read below reads it again and recomputes
      recomputeTtl()
      // a lifetime pinned by the option, the environment or the setting is what Claude Code asks for: no guessing over it.
      // Over the account's default, only a request after the one that last wrote under an older lifetime is evidence
      if (inferable && !(prev && prev.startedAt <= conv.ttlChangedAfter)) {
        const seen = observeTtl(prev, cur, conv.observed)
        if (seen !== conv.observed) {
          conv.observed = seen
          conv.ttl = seen ?? baseTtl
          conv.ttlSource = `observed from request timing; ${envSource} said ${baseTtl}`
          $.ui.log(`prompt-glance: cache lifetime is ${conv.ttl} (${conv.ttlSource})`, { to: 'debug' })
        }
      }
      conv.lastKey = ''
      void rereadAndRedraw($)
      if (showStatus) $.ui.status(shortLine(policy, Date.now()))
      $.ui.invalidate('ui.render')
    }
    return r
  })

  // every tool the main loop ran, and whether it failed, for the HUD's activity
  on('tool.call', async ($, e, next) => {
    const r = await next(e)
    if (!e.agentId) {
      const c = conv.tally.get(e.tool) ?? { ok: 0, failed: 0 }
      if ('deny' in r && r.deny !== undefined) c.failed += 1
      else if (r.isError) c.failed += 1
      else c.ok += 1
      conv.tally.set(e.tool, c)
      const name = e.tool === 'Skill' ? (e as { skill?: unknown }).skill : undefined
      if (typeof name === 'string' && name) conv.skills.set(name, (conv.skills.get(name) ?? 0) + 1)
      $.ui.invalidate('ui.render')
    }
    return r
  })

  on('command.run', { command: COMMAND }, async ($, e) => {
    if (e.args.trim().toLowerCase() === 'stop') {
      await $.ui.close({ id: PANE }).catch(() => undefined)
      isPaneOpen = false
      return { text: 'cache table closed' }
    }
    isPaneOpen = true
    await $.ui.open({ id: PANE, title: 'cache', focus: true })
    $.ui.invalidate('ui.render')
    const { advice } = current(policy, Date.now())
    return { text: `${conv.ttl} cache (${conv.ttlSource}) · ${advice.text} · /${COMMAND} stop closes` }
  })

  on('ui.close', async ($, e, next) => {
    if (e.id !== PANE) return next(e)
    isPaneOpen = false
    return next(e)
  })

  on('ui.press', async ($, e, next) => {
    if (e.plugin !== $.plugin.name || e.requestId !== PANE) return next(e)
    if (e.element === 'close') await $.ui.close({ id: PANE }).catch(() => undefined)
    return next(e)
  })

  // Two rows above the prompt, each a left group and a right group pushed to the edges:
  //   Opus 5.5  ~/Project/mod  git:(main*)              Turn $0.42 +0.8%  ● Cache 1h ████████████ 58m  hit 99.6%
  //   Context ███▌████████ 22%   5h █▎██████████ 10%   Week ▌███████████ 4%          Tools Bash×3  Edit×1
  // Labels are plain words; each gauge is a solid bar that warms from green to red along its length.
  // When the row is short, the richest variant that fits wins, so it never wraps.
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const yieldTo = !showBand ? 'off' : below ? undefined : e.props.hasSurvey ? 'survey' : isPaneOpen ? 'pane' : undefined
    if (!showBand || below || e.props.hasSurvey || isPaneOpen) {
      if (yieldTo) void note($, `above yields: ${yieldTo}`)
      return next(e)
    }
    try {
      // the band's own width, not the terminal's: the engine keeps five cells at the right end
      const { Box, rows } = drawHud($, e, e.props.bodyColumns ?? (e.viewport?.columns ?? 100) - 5, policy)
      void note($, 'above drawn')
      return <Box flexDirection="column">{rows}</Box>
    } catch (err) {
      void note($, `above error: ${String(err).slice(0, 200)}`)
      return next(e)
    }
  })

  // Under the prompt: the HUD, then the engine's own hint line (bypass mode, esc to interrupt) as dim text.
  on('ui.render', { component: 'PromptHint' }, async ($, e, next) => {
    if (!showBand || !below || isPaneOpen) {
      if (below && showBand) void note($, 'below yields: pane')
      return next(e)
    }
    try {
      const { Box, Text, rows } = drawHud($, e, (e.viewport?.columns ?? 100) - 4, policy)
      const hint = [e.props.hint, e.props.tail].filter(Boolean).join(' ')
      void note($, 'below drawn')
      return (
        <Box flexDirection="column">
          {rows}
          {hint ? <Text key="hint" dimColor>{hint}</Text> : null}
        </Box>
      )
    } catch (err) {
      void note($, `below error: ${String(err).slice(0, 200)}`)
      return next(e)
    }
  })

  on('ui.render', { component: 'Pane' }, async ($, e, next) => {
    if (e.requestId !== PANE) return next(e)
    const { Box, Text, Button } = $.ui.resolve(e)
    const width = Math.max(30, e.props.bodyColumns - 1)
    // HTML collapses runs of spaces and trims a text's ends; a no-break space keeps them
    const sp = (t: string) => (e.surface === 'terminal' ? t : t.replace(/ /g, ' '))
    const now = Date.now()
    const { last, advice, left } = current(policy, now)
    const all = byTurn(conv.samples)
    const counting = !!last && advice.kind !== 'uncached' && advice.kind !== 'off'
    // the countdown goes green, then yellow, then red as the cache runs out
    const clockColor = counting ? lifeColor(left, conv.ttl, policy.warnMs) : undefined
    const stateColor = advice.kind === 'expired' || advice.kind === 'miss' ? 'red' : (clockColor ?? COLOR[advice.kind])
    const hitColor = (pct: number) => (pct >= 80 ? 'green' : pct >= 40 ? 'yellow' : 'red')
    // solid bars are filled Boxes, not block characters, so HTML draws no seams between cells
    const solid = (key: string, parts: [number, string | undefined][]) => (
      <Box key={key} flexDirection="row" height={1} flexShrink={0}>
        {parts.map(([w, c], i) => (w > 0 ? <Box key={`${key}:${i}`} width={w} height={1} flexShrink={0} backgroundColor={c} /> : null))}
      </Box>
    )
    const cell = (key: string, w: number, text: string, c?: string, bold = false) => (
      <Box key={key} width={w} flexShrink={0} justifyContent="flex-end">
        <Text color={c} bold={bold} dimColor={!c}>{sp(text)}</Text>
      </Box>
    )

    const barW = Math.min(width, 40)
    const life = lifeRatio(left, conv.ttl)
    const lifeFilled = Math.round(life * barW)
    const [sr, sw, sn] = last ? segments(last.read, last.write, last.fresh, barW) : [0, 0, 0]
    // the latest turns that fit in the pane's own room, after the rows drawn around the table
    const around = PANE_FIXED_ROWS + (counting ? PANE_LIFE_BAR_ROWS : 0) + (last ? PANE_LAST_REQUEST_ROWS : 0)
    const rows = all.slice(-Math.max(PANE_MIN_TABLE_ROWS, e.props.scroll.bodyRows - around))
    const icon = advice.kind === 'warm' ? '●' : advice.kind === 'soon' ? '▲' : advice.kind === 'expired' || advice.kind === 'miss' ? '✖' : '○'

    return (
      <Box flexDirection="column">
        <Box key="title" flexDirection="row" columnGap={1}>
          <Text bold color="cyan">{sp('⚡ PROMPT CACHE')}</Text>
          <Text dimColor>{sp(`· ${conv.ttl} lifetime (${conv.ttlSource})`)}</Text>
        </Box>

        <Box key="clock" flexDirection="column" marginTop={1}>
          <Text bold color={clockColor}>{sp(counting ? `⏱ ${left > 0 ? fmtClock(left) : '0:00'}` : '⏱ --:--')}</Text>
          {counting ? (
            <Box flexDirection="row" columnGap={1}>
              {solid('life', [[lifeFilled, clockColor], [barW - lifeFilled, 'gray']])}
              <Text dimColor>{sp(`${Math.round(life * 100)}%`)}</Text>
            </Box>
          ) : null}
        </Box>

        <Box key="advice" marginTop={1} flexDirection="column">
          <Text bold color={stateColor}>{sp(`${icon} ${advice.text}`)}</Text>
          {last ? <Text dimColor>{sp(fit(`${last.model} · prompt ${fmtTokens(promptTokens(last))} tokens`, width))}</Text> : null}
        </Box>

        {last ? (
          <Box key="stack" flexDirection="column" marginTop={1}>
            <Box flexDirection="row" columnGap={1}>
              {solid('stack', [[sr, 'green'], [sw, 'yellow'], [sn, 'cyan']])}
              <Text bold color={hitColor(Math.round(hitRatio(last) * 100))}>{sp(`${Math.round(hitRatio(last) * 100)}% hit`)}</Text>
            </Box>
            <Box flexDirection="row" columnGap={2}>
              <Text color="green">{sp(`■ read ${fmtTokens(last.read)}`)}</Text>
              <Text color="yellow">{sp(`■ wrote ${fmtTokens(last.write)}`)}</Text>
              <Text color="cyan">{sp(`■ new ${fmtTokens(last.fresh)}`)}</Text>
            </Box>
          </Box>
        ) : null}

        <Box key="table" flexDirection="column" marginTop={1}>
          <Box key="head" flexDirection="row" columnGap={1}>
            {cell('h:turn', 4, 'turn', 'cyan', true)}
            {cell('h:steps', 5, 'steps', 'cyan', true)}
            {cell('h:read', 6, 'read', 'green', true)}
            {cell('h:wrote', 6, 'wrote', 'yellow', true)}
            {cell('h:new', 5, 'new', 'cyan', true)}
            {cell('h:hit', 4, 'hit', 'magenta', true)}
          </Box>
          {rows.length === 0 ? <Text dimColor>{sp('no requests yet')}</Text> : null}
          {rows.map((row, i) => {
            const n = conv.turnNo.get(row.turnId) ?? all.length - rows.length + i + 1
            const pct = Math.round(rowRatio(row) * 100)
            return (
              <Box key={`t:${row.turnId}`} flexDirection="row" columnGap={1}>
                {cell(`c:turn:${row.turnId}`, 4, String(n))}
                {cell(`c:steps:${row.turnId}`, 5, String(row.steps))}
                {cell(`c:read:${row.turnId}`, 6, fmtTokens(row.read), 'green')}
                {cell(`c:wrote:${row.turnId}`, 6, fmtTokens(row.write), 'yellow')}
                {cell(`c:new:${row.turnId}`, 5, fmtTokens(row.fresh), 'cyan')}
                {cell(`c:hit:${row.turnId}`, 4, `${pct}%`, hitColor(pct), true)}
              </Box>
            )
          })}
        </Box>

        <Box key="foot" marginTop={1} flexDirection="column">
          <Button key="close" label="close" onPress={() => {}} />
          <Box key="legend" marginTop={1} flexDirection="column">
            <Text color="green">{sp('■ read: served by the cache')}</Text>
            <Text color="yellow">{sp('■ wrote: new cache entry')}</Text>
            <Text color="cyan">{sp('■ new: sent uncached')}</Text>
          </Box>
        </Box>
      </Box>
    )
  })
}
