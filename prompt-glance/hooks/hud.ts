// The HUD's pure helpers: gauges, short times and labels, all testable without the engine.
import type { Advice, BandSeg } from './cache.ts'

/** A gauge of `width` cells: █ filled, ░ empty, at least one █ above zero. */
export function gauge(pct: number, width: number): string {
  const p = Math.min(100, Math.max(0, pct))
  const filled = p > 0 ? Math.max(1, Math.round((p / 100) * width)) : 0
  return '█'.repeat(filled) + '░'.repeat(width - filled)
}

// five steps from calm to alarm: green, lime, yellow, orange, red
export const HEAT = ['#22c55e', '#a3e635', '#facc15', '#fb923c', '#ef4444'] as const

/** Where each step starts: the context window degrades sooner than a plan window runs out. */
export const SCALE = {
  context: [30, 50, 65, 80],
  window: [40, 60, 75, 90],
} as const

/** The step's colour for `pct` on `scale`. */
export function heat(pct: number, scale: readonly number[]): string {
  const i = scale.filter(step => pct >= step).length
  return HEAT[Math.min(i, HEAT.length - 1)] ?? HEAT[0]
}

/** The empty part of every track. */
export const TRACK = '#3a3f4b'

// a cell filled by eighths, left to right
const EIGHTHS = ['', '▏', '▎', '▍', '▌', '▋', '▊', '▉']

/**
 * A solid bar: full cells of █, the last one filled by eighths over the track's
 * colour, so it moves smoothly instead of a cell at a time. `colorAt(p)` colours
 * the cell standing for p% (a heat strip warms along its length).
 */
function solidGauge(ratio: number, width: number, colorAt: (p: number) => string | undefined): BandSeg[] {
  const exact = Math.min(1, Math.max(0, ratio)) * width
  let full = Math.floor(exact)
  let frac = Math.round((exact - full) * 8)
  if (frac === 8) {
    full += 1
    frac = 0
  }
  if (ratio > 0 && full === 0 && frac === 0) frac = 1
  const segs: BandSeg[] = []
  for (let i = 0; i < width; i++) {
    const color = colorAt(((i + 1) / width) * 100)
    if (i < full) segs.push({ text: '█', color })
    else if (i === full && frac > 0) segs.push({ text: EIGHTHS[frac] ?? '', color, backgroundColor: TRACK })
    else segs.push({ text: '█', color: TRACK })
  }
  return merge(segs)
}

/** A heat strip: each filled cell takes the colour of the level it stands for, so a fuller bar reads warmer. */
export function heatGauge(pct: number, width: number, scale: readonly number[]): BandSeg[] {
  return solidGauge(pct / 100, width, p => heat(p, scale))
}

/** A bar of `width` cells filled to `ratio` in one colour. */
export function lineGauge(ratio: number, width: number, color: string | undefined): BandSeg[] {
  return solidGauge(ratio, width, () => color)
}

// neighbours of one style draw as one piece
function merge(segs: BandSeg[]): BandSeg[] {
  return segs.reduce<BandSeg[]>((out, seg) => {
    const prev = out[out.length - 1]
    if (prev && prev.color === seg.color && prev.backgroundColor === seg.backgroundColor && prev.dim === seg.dim && prev.bold === seg.bold) prev.text += seg.text
    else out.push({ ...seg })
    return out
  }, [])
}

/** `git status --porcelain -b`: the branch, whether the tree is dirty, and how far it is from upstream. */
export function parseGitStatus(stdout: string): { branch: string; dirty: boolean; ahead: number; behind: number } {
  const lines = stdout.split('\n').filter(Boolean)
  const first = lines[0] ?? ''
  const head = first.startsWith('## ') ? first.slice(3) : ''
  const name = head.startsWith('No commits yet on ') ? head.slice(18) : (head.split('...')[0] ?? '').split(' ')[0] ?? ''
  return {
    branch: name === 'HEAD' ? 'detached' : name,
    dirty: lines.length > 1,
    ahead: Number(/ahead (\d+)/.exec(head)?.[1] ?? 0),
    behind: Number(/behind (\d+)/.exec(head)?.[1] ?? 0),
  }
}

/** The working directory with `~` for home, keeping its last `levels` folders (all when undefined). */
export function shortPath(cwd: string, home: string | undefined, levels?: number): string {
  const tilde = home && (cwd === home || cwd.startsWith(home + '/')) ? '~' + cwd.slice(home.length) : cwd
  if (levels === undefined) return tilde
  const parts = tilde.split('/').filter(Boolean)
  return parts.length <= levels ? tilde : parts.slice(-levels).join('/')
}

/** How far into a plan window we are, 0-100, from its reset time and length. */
export function elapsedPct(resetsAt: number | undefined, windowMs: number, now: number): number | undefined {
  if (resetsAt === undefined || !Number.isFinite(resetsAt)) return undefined
  return Math.min(100, Math.max(0, (1 - (resetsAt - now) / windowMs) * 100))
}

/** The largest unit only: 45s, 59m, 3h, 6d. */
export function fmtShort(ms: number): string {
  const s = Math.max(0, Math.ceil(ms / 1000))
  if (s < 60) return `${s}s`
  const m = Math.round(s / 60)
  if (m < 90) return `${m}m`
  const h = Math.round(m / 60)
  if (h < 48) return `${h}h`
  return `${Math.round(h / 24)}d`
}

/** `claude-opus-5-5` (or `claude-opus-5-5[1m]`) as `Opus 5.5`; anything else unchanged. */
export function prettyModel(id: string): string {
  const [, family, major, minor] = /claude-([a-z]+)-(\d+)(?:-(\d+))?/i.exec(id) ?? []
  if (!family || !major) return id
  const name = family.charAt(0).toUpperCase() + family.slice(1)
  return minor && minor.length <= 2 ? `${name} ${major}.${minor}` : `${name} ${major}`
}

/** Each model family in a calm colour of its own, so a switch shows at a glance. */
export function modelColor(pretty: string): string {
  const family = (pretty.split(' ')[0] ?? '').toLowerCase()
  return ({ opus: '#e0af68', sonnet: '#7aa2f7', haiku: '#9ece6a', fable: '#bb9af7' } as Record<string, string>)[family] ?? '#c0caf5'
}

/**
 * Words for the cache's state, only when there is something to do: warm says
 * nothing, the bar says it. A lapsed cache names what the next message costs.
 */
export function shortAdvice(advice: Advice, recache?: string): { text: string } {
  switch (advice.kind) {
    case 'warm':
      return { text: '' }
    case 'soon':
      return { text: 'expiring · send a message' }
    case 'expired': {
      const next = recache ? `next message re-caches ${recache} tokens` : 'next message re-caches'
      return { text: advice.text.includes('/compact') ? `${next} · /compact first` : next }
    }
    case 'miss':
      return { text: 'missed' }
    case 'uncached':
      return { text: 'not cached' }
    case 'off':
      return { text: 'caching off' }
    case 'cold':
      return { text: 'waiting for first request' }
  }
}

/** A hit rate that never rounds up to a 100% it is not: 99.5% stays 99.5%. */
export function fmtPct(ratio: number): string {
  const p = Math.min(1, Math.max(0, ratio)) * 100
  if (p >= 100) return '100%'
  if (p >= 99) return `${(Math.floor(p * 10) / 10).toFixed(1)}%`
  return `${Math.floor(p)}%`
}

/** Tool counts, most used first: `[name, ok, failed]`. */
export type ToolTally = Map<string, { ok: number; failed: number }>

export function topTools(tally: ToolTally, n: number): [string, number, number][] {
  return [...tally.entries()]
    .map(([name, c]) => [name.split('__').pop() ?? name, c.ok, c.failed] as [string, number, number])
    .sort((a, b) => b[1] + b[2] - (a[1] + a[2]))
    .slice(0, n)
}

/** Dollars: cents under $100, whole dollars from there, "<$0.01" for a crumb. */
export function fmtUsd(usd: number): string {
  if (usd > 0 && usd < 0.01) return '<$0.01'
  return usd >= 100 ? `$${Math.round(usd)}` : `$${usd.toFixed(2)}`
}

/** A turn's share of the 5-hour window: quiet under 1%, yellow to 3%, red past it. */
export function deltaColor(pct: number): string {
  return pct > 3 ? 'red' : pct > 1 ? 'yellow' : 'gray'
}

/**
 * What a turn spent, from the figures at its start to now: dollars and the
 * plan windows' growth. A window that reset during the turn counts from zero.
 * Undefined before any turn has started.
 */
export function turnSpend(
  base: { usd?: number; five?: number; week?: number } | undefined,
  usd: number | undefined,
  five: number | undefined,
  week: number | undefined,
): { usd?: number; five?: number; week?: number } | undefined {
  if (!base) return undefined
  const grow = (from: number | undefined, to: number | undefined) =>
    to === undefined ? undefined : from === undefined || to < from ? to : to - from
  return {
    usd: usd === undefined ? undefined : Math.max(0, usd - (base.usd ?? 0)),
    five: base.five === undefined && five === undefined ? undefined : grow(base.five, five),
    week: base.week === undefined && week === undefined ? undefined : grow(base.week, week),
  }
}

/** The REST quota as the HUD shows it: the share used, or anon when gh has no usable token. */
export type GhQuota = { anon: false; pct: number; resetsAt: number } | { anon: true }

/** Without a token (an SSH session can't reach the macOS keychain) the API hands out the anonymous 60. */
const ANON_LIMIT = 60

/** Parses `gh api rate_limit --jq` output of `remaining<TAB>limit<TAB>reset`; undefined when it is not that. */
export function parseRateLimit(stdout: string): GhQuota | undefined {
  const fields = stdout.trim().split('\t')
  if (fields.length !== 3 || fields.includes('')) return undefined
  const [remaining, limit, reset] = fields.map(Number)
  if (remaining === undefined || limit === undefined || reset === undefined || [remaining, limit, reset].some(Number.isNaN) || limit <= 0) return undefined
  if (limit <= ANON_LIMIT) return { anon: true }
  return { anon: false, pct: ((limit - remaining) / limit) * 100, resetsAt: reset * 1000 }
}
