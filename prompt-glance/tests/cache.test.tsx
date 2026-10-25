// Run with: claude plugin test .
import { describe, expect, mock, test } from 'claude-code/testing'
import {
  advise,
  lifeColor,
  segments,
  observeTtl,
  decideTtl,
  accountOf,
  nextToastMark,
  bar,
  byTurn,
  fmtClock,
  fmtTokens,
  hitRatio,
  isCachingDisabled,
  missReason,
  remainingMs,
  resolveTtl,
  cells,
  countMisses,
  sessionHit,
  fitBand,
} from '../hooks/cache'
import type { Policy, Sample } from '../hooks/cache'
import { deltaColor, parseRateLimit, shortAdvice, fmtPct, fmtShort, fmtUsd, gauge, heat, modelColor, turnSpend, heatGauge, HEAT, parseGitStatus, prettyModel, SCALE, shortPath, topTools, TRACK } from '../hooks/hud'
import type { Engine } from 'claude-code/testing'
import type { On } from 'claude-code'

const T0 = 1_000_000_000_000
const policy: Policy = { ttl: '5m', warnMs: 60_000, compactAtTokens: 100_000 }

const sample = (over: Partial<Sample> = {}): Sample => ({
  turnId: 't1',
  index: 0,
  model: 'claude-sonnet-5-5',
  startedAt: T0,
  read: 80_000,
  write: 1_000,
  fresh: 500,
  output: 300,
  ...over,
})

describe('ttl and switches', () => {
  test('auto follows the environment; the option wins; FORCE_5M beats ENABLE_1H', () => {
    expect(resolveTtl('auto', {})).toBe('5m')
    expect(resolveTtl('auto', { enable1h: '1' })).toBe('1h')
    expect(resolveTtl('auto', { enable1h: '1', force5m: '1' })).toBe('5m')
    expect(resolveTtl('1h', { force5m: '1' })).toBe('1h')
    expect(resolveTtl(undefined, { enable1h: 'true' })).toBe('1h')
  })

  test('DISABLE_PROMPT_CACHING variants are per model family', () => {
    expect(isCachingDisabled('claude-opus-5-5', { disableAll: '1' })).toBe(true)
    expect(isCachingDisabled('claude-opus-5-5', { disableSonnet: '1' })).toBe(false)
    expect(isCachingDisabled('claude-sonnet-5-5', { disableSonnet: '1' })).toBe(true)
    expect(isCachingDisabled('claude-haiku-4-5', { disableHaiku: '1' })).toBe(true)
  })
})

describe('the countdown counts from the start of the request', () => {
  test('remaining time and expiry', () => {
    const s = sample()
    expect(remainingMs(s, '5m', T0 + 100_000)).toBe(200_000)
    expect(remainingMs(s, '1h', T0 + 100_000)).toBe(3_500_000)
    expect(remainingMs(s, '5m', T0 + 400_000)).toBe(0)
  })

  test('a request that touched no cache has no countdown', () => {
    expect(remainingMs(sample({ read: 0, write: 0 }), '5m', T0 + 1000)).toBe(0)
  })

  test('formatting', () => {
    expect(fmtClock(200_000)).toBe('3:20')
    expect(fmtClock(3_500_000)).toBe('58:20')
    expect(fmtClock(3_600_000)).toBe('1:00:00')
    expect(fmtClock(1)).toBe('0:01')
    expect(fmtTokens(950)).toBe('950')
    expect(fmtTokens(84_200)).toBe('84.2k')
    expect(fmtTokens(182_000)).toBe('182k')
    expect(fmtTokens(1_200_000)).toBe('1.2M')
    expect(bar(0.5, 10)).toBe('█████░░░░░')
    expect(Math.round(hitRatio(sample()) * 1000)).toBe(982)
  })
})

describe('advice', () => {
  test('warm, then soon, then expired', () => {
    const s = sample()
    expect(advise(s, undefined, policy, T0 + 10_000, false).kind).toBe('warm')
    expect(advise(s, undefined, policy, T0 + 250_000, false).kind).toBe('soon')
    expect(advise(s, undefined, policy, T0 + 300_000, false).kind).toBe('expired')
  })

  test('an expired large context suggests /compact, a small one says keep going', () => {
    const big = advise(sample({ read: 150_000 }), undefined, policy, T0 + 400_000, false)
    expect(big.text).toContain('/compact')
    const small = advise(sample({ read: 5_000, write: 100, fresh: 50 }), undefined, policy, T0 + 400_000, false)
    expect(small.text).toContain('keep going')
    expect(small.text).not.toContain('/compact')
  })

  test('the 1h cache stays warm where the 5m one has lapsed', () => {
    const s = sample()
    expect(advise(s, undefined, { ...policy, ttl: '1h' }, T0 + 1_000_000, false).kind).toBe('warm')
  })

  test('off, cold and uncached', () => {
    expect(advise(sample(), undefined, policy, T0, true).kind).toBe('off')
    expect(advise(undefined, undefined, policy, T0, false).kind).toBe('cold')
    expect(advise(sample({ read: 0, write: 0, fresh: 900 }), undefined, policy, T0, false).kind).toBe('uncached')
  })
})

describe('misses', () => {
  const prev = sample({ read: 50_000, write: 1_000, fresh: 200 })

  test('names the cause', () => {
    const wrote = { read: 0, write: 52_000, fresh: 300 }
    expect(missReason(prev, sample({ ...wrote, model: 'claude-opus-5-5', startedAt: T0 + 20_000 }), '5m')).toContain('model changed')
    expect(missReason(prev, sample({ ...wrote, startedAt: T0 + 400_000 }), '5m')).toContain('had lapsed')
    expect(missReason(prev, sample({ ...wrote, startedAt: T0 + 20_000 }), '5m')).toContain('prefix changed')
  })

  test('a hit, a first request and a /compact are not misses', () => {
    expect(missReason(prev, sample({ read: 51_000, write: 400, fresh: 100 }), '5m')).toBeUndefined()
    expect(missReason(undefined, sample(), '5m')).toBeUndefined()
    expect(missReason(prev, sample({ read: 0, write: 8_000, fresh: 100 }), '5m')).toBeUndefined()
  })

  test('advise reports a miss while the entry is still live', () => {
    const cur = sample({ read: 0, write: 52_000, fresh: 300, startedAt: T0 + 20_000 })
    const a = advise(cur, prev, policy, T0 + 30_000, false)
    expect(a.kind).toBe('miss')
    expect(a.text).toContain('prefix changed')
  })
})

describe('per-turn rows', () => {
  test('requests of one turn are summed', () => {
    const rows = byTurn([
      sample({ turnId: 'a', index: 0, read: 10, write: 5, fresh: 1 }),
      sample({ turnId: 'a', index: 1, read: 15, write: 0, fresh: 2 }),
      sample({ turnId: 'b', index: 0, read: 20, write: 0, fresh: 3 }),
    ])
    expect(rows.length).toBe(2)
    expect(rows[0]).toEqual(expect.objectContaining({ turnId: 'a', steps: 2, read: 25, write: 5, fresh: 3 }))
    expect(rows[1]?.steps).toBe(1)
  })
})

// The module end to end: a main-loop request feeds the band, a subagent's does not.
type Calls = { status: (string | undefined)[]; logs: string[]; toasts?: string[]; closed?: string[] }

let ghRate = ''
// how gh exits beside ghRate: 4 and 'gh auth login' when it was never logged in
let ghExit = { exitCode: 0, stderr: '' }
// the model the session reports; a test changes it to stand for a /model switch
let modelId = 'claude-opus-5-5'
// every command the module ran, and a hook that answers git status in its place (a slow repo)
let argvs: string[][] = []
let gitRun: (() => Promise<unknown>) | undefined
// holds back the next session.usage answer, read when asked, until the promise settles: a reading that lands late
let usageHold: Promise<unknown> | undefined
// set once the held answer has gone back to the module
let usageHeldOut = false

function fakeEngine(
  on: On,
  env: Record<string, string>,
  calls: Calls,
  cache = { read: 80_000, write: 1_000 },
  limits: { kind: string; percentUsed: number; resetsAt?: string }[] = [],
  money?: { usd: number },
  { clock = true } = {},
) {
  argvs = []
  gitRun = undefined
  usageHold = undefined
  usageHeldOut = false
  ghRate = ''
  modelId = 'claude-opus-5-5'
  ghExit = { exitCode: 0, stderr: '' }
  on('session.usage', async () => {
    const value = { startedAt: 0, context: {}, rateLimits: limits, ...(money ? { cost: { usd: money.usd } } : {}) }
    const hold = usageHold
    usageHold = undefined
    if (hold) {
      await hold
      usageHeldOut = true
    }
    return { value } as never
  })
  on('turn.start', async ($, e) => ({ turnId: e.turnId }) as never)
  on('session.start', async ($, e) => ({ cwd: e.cwd }) as never)
  on('session.end', async () => ({ sessionId: 's1' }) as never)
  on('env.get', ($, e) => ({ value: env[e.name] }))
  on('session.model', () => ({ value: modelId }) as never)
  // gh's rate_limit answers ghRate (nothing parseable by default); git status and gh --version the branch
  on('process.run', async ($, e) => {
    const argv = (e as { argv: string[] }).argv
    argvs.push(argv)
    if (argv.includes('status') && gitRun) return (await gitRun()) as never
    if (argv[1] === 'api') return { value: { stdout: ghRate, ...ghExit } } as never
    return { value: { exitCode: 0, stdout: '## main...origin/main [ahead 1]\n M hooks/x.ts\n', stderr: '' } } as never
  })
  on('command.register', () => ({ value: undefined }) as never)
  if (clock) on('clock.every', () => ({ value: undefined }) as never)
  on('ui.open', () => ({ value: undefined }) as never)
  on('ui.close', ($, e) => {
    calls.closed?.push((e as { id: string }).id)
    return { value: undefined } as never
  })
  on('ui.invalidate', () => ({ value: undefined }) as never)
  on('ui.toast', ($, e) => {
    calls.toasts?.push(String((e as { text: unknown }).text))
    return { value: undefined }
  })
  on('ui.log', ($, e) => {
    calls.logs.push(String((e as { text: unknown }).text))
    return { value: undefined }
  })
  on('ui.status', ($, e) => {
    calls.status.push((e as { text?: string }).text)
    return { value: undefined }
  })
  on('turn.step', async function* ($, e) {
    return {
      turnId: e.turnId,
      index: e.index,
      answer: '',
      toolUses: [],
      stopReason: 'end_turn',
      usage: { model: 'claude-sonnet-5-5', input_tokens: 300, output_tokens: 50, cache_read_input_tokens: cache.read, cache_creation_input_tokens: cache.write },
    } as never
  })
}

async function step($: Engine, over: { turnId?: string; index?: number; agentId?: string } = {}) {
  const stream = $.turn.step({ turnId: 't1', index: 0, model: 'claude-sonnet-5-5', messageCount: 3, ...over } as never)
  for (;;) {
    const n = await stream.next()
    if (n.done) return n.value
  }
}

const BAND = { hasSurvey: false } as never
const band = ($: Engine) => $.ui.mount({ plugin: 'prompt-glance', surface: 'terminal', component: 'AbovePrompt', props: BAND })

describe('the band', () => {
  test('shows nothing before the first request, then the hit rate and the countdown', { options: { status: true } }, async ($, on) => {
    const calls: Calls = { status: [], logs: [] }
    fakeEngine(on, {}, calls)
    await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true } as never)

    expect(calls.status).toEqual([])
    await step($)
    const ui = await band($)
    expect(await ui.find({ type: 'Text', text: /^Opus 5\.5$/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /^\/repo$/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /^main$/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /^\*$/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /^ ↑1$/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /^[45]m$/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /^[45]m$/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /^98%$/ })).toBeDefined()
    await ui.unmount()
    expect(calls.status.at(-1)).toMatch(/^cache 98% · [45]:\d\d$/)
  })

  test('a subagent request is not the main loop and leaves the meter alone', { options: { status: true } }, async ($, on) => {
    const calls: Calls = { status: [], logs: [] }
    fakeEngine(on, {}, calls)
    await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true } as never)
    await step($, { agentId: 'agent-1' })
    expect(calls.status.filter(t => t?.includes('%'))).toEqual([])
    await step($)
    expect(calls.status.filter(t => t?.includes('%')).length).toBe(1)
  })

  test('a narrow band stacks its groups instead of dropping them', async ($, on) => {
    const calls: Calls = { status: [], logs: [] }
    fakeEngine(on, {}, calls, undefined, [
      { kind: 'five_hour', percentUsed: 9 },
      { kind: 'seven_day', percentUsed: 4 },
    ])
    await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true } as never)
    await step($)
    const ui = await $.ui.mount({ plugin: 'prompt-glance', surface: 'terminal', component: 'AbovePrompt', props: { hasSurvey: false, bodyColumns: 45 } as never })
    // nothing dropped: the path, the countdown and every window are still there, the labels padded alike
    expect(await ui.find({ type: 'Text', text: /^\/repo$/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /^60m$/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /^Cache   $/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /^Week    $/ })).toBeDefined()
    await ui.unmount()
  })

  test('tools and skills show by name and count when wide; a narrow band leaves them out', async ($, on) => {
    const calls: Calls = { status: [], logs: [] }
    fakeEngine(on, {}, calls)
    on('tool.call', async () => ({ result: 'ok' }) as never)
    await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true } as never)
    await step($)
    for (let i = 0; i < 3; i++) await $.tool.call({ tool: 'Bash', command: 'ls' } as never)
    await $.tool.call({ tool: 'Skill', skill: 'plugin-authoring' } as never)
    const ui = await $.ui.mount({ plugin: 'prompt-glance', surface: 'terminal', component: 'AbovePrompt', props: { hasSurvey: false, bodyColumns: 160 } as never })
    expect(await ui.find({ type: 'Text', text: /^Tools $/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /^Bash$/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /^×3$/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /^Skills $/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /^plugin-authoring$/ })).toBeDefined()
    await ui.unmount()
    const narrow = await $.ui.mount({ plugin: 'prompt-glance', surface: 'terminal', component: 'AbovePrompt', props: { hasSurvey: false, bodyColumns: 45 } as never })
    expect(await narrow.find({ type: 'Text', text: /^Bash$/ })).toBeUndefined()
    expect(await narrow.find({ type: 'Text', text: /^Cache/ })).toBeDefined()
    await narrow.unmount()
  })

  test('the turn shows what it spent, the session its total', async ($, on) => {
    const calls: Calls = { status: [], logs: [] }
    const money = { usd: 1.2 }
    const five = { kind: 'five_hour', percentUsed: 10 }
    fakeEngine(on, {}, calls, undefined, [five], money)
    await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true } as never)
    await $.turn.start({ text: 'hi', turnId: 't1' } as never)
    money.usd = 1.62
    five.percentUsed = 10.8
    await step($)
    const ui = await $.ui.mount({ plugin: 'prompt-glance', surface: 'terminal', component: 'AbovePrompt', props: { hasSurvey: false, bodyColumns: 160 } as never })
    expect(await ui.find({ type: 'Text', text: /^Turn $/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /^\$0\.42$/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /^ \+0\.8%$/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /^\$1\.62$/ })).toBeDefined()
    await ui.unmount()
  })

  test('a plan window always shows its percentage, its reset only past half', async ($, on) => {
    const calls: Calls = { status: [], logs: [] }
    fakeEngine(on, {}, calls, undefined, [
      { kind: 'five_hour', percentUsed: 72, resetsAt: new Date(Date.now() + 3 * 3600_000).toISOString() },
      { kind: 'seven_day', percentUsed: 3 },
    ] as never)
    await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true } as never)
    await step($)
    const ui = await $.ui.mount({ plugin: 'prompt-glance', surface: 'terminal', component: 'AbovePrompt', props: { hasSurvey: false, bodyColumns: 150 } as never })
    expect(await ui.find({ type: 'Text', text: /^ 72%$/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /^Week $/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /^ ↻3h$/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /^ 3%$/ })).toBeDefined()
    await ui.unmount()
  })

  test('ENABLE_PROMPT_CACHING_1H makes the lifetime an hour; the option beats the environment', async ($, on) => {
    const calls: Calls = { status: [], logs: [] }
    fakeEngine(on, { ENABLE_PROMPT_CACHING_1H: '1' }, calls)
    await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true } as never)
    await loaded(calls)
    expect(calls.logs.join('\n')).toContain('1h cache (ENABLE_PROMPT_CACHING_1H)')
    await step($)
    const ui = await band($)
    expect(await ui.find({ type: 'Text', text: /^(59|60)m$/ })).toBeDefined()
    await ui.unmount()
  })

  test('a Claude subscription defaults to an hour, usage credits to five minutes', async ($, on) => {
    const calls: Calls = { status: [], logs: [] }
    fakeEngine(on, {}, calls, undefined, [{ kind: 'five_hour', percentUsed: 12 }])
    await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true } as never)
    await loaded(calls)
    expect(calls.logs.join('\n')).toContain('1h cache (Claude subscription default)')
  })

  test('CLAUDE_CODE_PROMPT_CACHE_TTL beats the subscription default', async ($, on) => {
    const calls: Calls = { status: [], logs: [] }
    fakeEngine(on, { CLAUDE_CODE_PROMPT_CACHE_TTL: '5m' }, calls, undefined, [{ kind: 'five_hour', percentUsed: 12 }])
    await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true } as never)
    await loaded(calls)
    expect(calls.logs.join('\n')).toContain('5m cache (CLAUDE_CODE_PROMPT_CACHE_TTL)')
  })

  test('the ttl option beats the environment', { options: { ttl: '5m' } }, async ($, on) => {
    const calls: Calls = { status: [], logs: [] }
    fakeEngine(on, { ENABLE_PROMPT_CACHING_1H: '1' }, calls)
    await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true } as never)
    await loaded(calls)
    expect(calls.logs.join('\n')).toContain('5m cache (the ttl option)')
  })

  test('a request that touched no cache shows no countdown', async ($, on) => {
    const calls: Calls = { status: [], logs: [] }
    fakeEngine(on, {}, calls, { read: 0, write: 0 })
    await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true } as never)
    await step($)
    const ui = await band($)
    expect(await ui.find({ type: 'Text', text: /not cached/ })).toBeDefined()
    // no lifetime label and no time left: what the band draws only while it counts down
    expect(await ui.find({ type: 'Text', text: /^(5m|1h) $/ })).toBeUndefined()
    expect(await ui.find({ type: 'Text', text: /^\d+[smhd]$/ })).toBeUndefined()
    expect(await ui.find({ type: 'Text', text: /^  hit $/ })).toBeDefined()
    await ui.unmount()
  })

  test('DISABLE_PROMPT_CACHING says so instead of a countdown', async ($, on) => {
    const calls: Calls = { status: [], logs: [] }
    fakeEngine(on, { DISABLE_PROMPT_CACHING: '1' }, calls)
    await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true } as never)
    const ui = await band($)
    expect(await ui.find({ type: 'Text', text: /caching off/ })).toBeDefined()
    await ui.unmount()

    // after a request the band still shows no countdown
    await step($)
    const after = await band($)
    expect(await after.find({ type: 'Text', text: /caching off/ })).toBeDefined()
    expect(await after.find({ type: 'Text', text: /^(5m|1h) $/ })).toBeUndefined()
    expect(await after.find({ type: 'Text', text: /^\d+[smhd]$/ })).toBeUndefined()
    await after.unmount()
  })
})

describe('one-line band', () => {
  const P = (key: string, text: string) => ({ key, text })
  const rich = [P('a', 'cache'), P('b', '██████████'), P('c', 'read 59k'), P('d', 'wrote 644'), P('e', 'new 2'), P('f', '⏱ 59:28')]
  const poor = [P('a', 'cache'), P('f', '⏱ 59:28')]
  const tail = P('t', '1h · warm: keep going')
  const width = (parts: { text: string }[]) => parts.reduce((n, p) => n + cells(p.text), 0) + parts.length - 1

  test('the richest layout that fits wins, and the tail takes the rest', () => {
    const parts = fitBand([rich, poor], tail, 200)
    expect(parts.map(p => p.key)).toEqual(['a', 'b', 'c', 'd', 'e', 'f', 't'])
    expect(parts.at(-1)?.text).toBe('1h · warm: keep going')
  })
  test('never wider than the band: a narrow one falls back and truncates the tail', () => {
    for (const w of [80, 60, 40, 30, 22]) {
      const parts = fitBand([rich, poor], tail, w)
      expect(width(parts)).toBeLessThanOrEqual(w)
    }
    expect(fitBand([rich, poor], tail, 40).map(p => p.key)).toEqual(['a', 'f', 't'])
    expect(fitBand([rich, poor], tail, 66).at(-1)?.text.endsWith('…')).toBe(true)
  })
  test('⏱ counts two cells', () => {
    expect(cells('⏱ 1:00')).toBe(7)
  })
})

describe('hud helpers', () => {
  test('gauges, short times and model names', () => {
    expect(gauge(0, 5)).toBe('░░░░░')
    expect(gauge(3, 5)).toBe('█░░░░')
    expect(gauge(100, 5)).toBe('█████')
    expect(fmtShort(45_000)).toBe('45s')
    expect(fmtShort(59 * 60_000)).toBe('59m')
    expect(fmtShort(3.4 * 3600_000)).toBe('3h')
    expect(fmtShort(6.6 * 86400_000)).toBe('7d')
    expect(prettyModel('claude-opus-5-5')).toBe('Opus 5.5')
    expect(prettyModel('claude-haiku-4-5-20251001')).toBe('Haiku 4.5')
    expect(cells('🧠 保溫中')).toBe(9)
    expect(modelColor('Opus 5.5')).not.toBe(modelColor('Sonnet 5'))
    expect(modelColor('Mystery 1')).toBe('#c0caf5')
    expect(fmtPct(0.995)).toBe('99.5%')
    expect(fmtPct(0.9999)).toBe('99.9%')
    expect(fmtPct(1)).toBe('100%')
    expect(fmtPct(0.876)).toBe('87%')
  })
  test('git status and the path', () => {
    expect(parseGitStatus('## main...origin/main [ahead 2, behind 1]\n M a\n')).toEqual({ branch: 'main', dirty: true, ahead: 2, behind: 1 })
    expect(parseGitStatus('## feat/x\n')).toEqual({ branch: 'feat/x', dirty: false, ahead: 0, behind: 0 })
    expect(parseGitStatus('## No commits yet on main\n')).toEqual({ branch: 'main', dirty: false, ahead: 0, behind: 0 })
    expect(shortPath('/Users/a/Project/mod', '/Users/a')).toBe('~/Project/mod')
    expect(shortPath('/Users/a/Project/mod/x', '/Users/a', 2)).toBe('mod/x')
    expect(shortPath('/opt/x', '/Users/a', 1)).toBe('x')
  })
  test('session hit rate and misses count every main-loop request', () => {
    const a = sample({ index: 0, read: 0, write: 50_000, fresh: 100, startedAt: T0 })
    const b = sample({ index: 1, read: 50_000, write: 500, fresh: 10, startedAt: T0 + 10_000 })
    const c = sample({ index: 2, read: 0, write: 51_000, fresh: 10, startedAt: T0 + 20_000, model: 'claude-opus-5-5' })
    expect(sessionHit([a, b])).toBe(50_000 / 100_610)
    expect(countMisses([a, b], '5m')).toBe(0)
    expect(countMisses([a, b, c], '5m')).toBe(1)
    expect(shortAdvice({ kind: 'expired', text: 'expired: only 8k tokens to rebuild' }, '82k').text).toBe('next message re-caches 82k tokens')
  })
  test('a turn spends dollars and a share of the 5-hour window', () => {
    expect(turnSpend(undefined, 1, 10, 3)).toBeUndefined()
    expect(turnSpend({ usd: 1.2, five: 10, week: 3 }, 1.62, 10.8, 3.1)).toEqual({ usd: 1.62 - 1.2, five: 10.8 - 10, week: 3.1 - 3 })
    // the window reset mid-turn: count from zero
    expect(turnSpend({ usd: 0, five: 98 }, 0.1, 0.5, undefined)?.five).toBe(0.5)
    expect(fmtUsd(0.004)).toBe('<$0.01')
    expect(fmtUsd(0.42)).toBe('$0.42')
    expect(fmtUsd(123.4)).toBe('$123')
    expect(deltaColor(0.5)).toBe('gray')
    expect(deltaColor(2)).toBe('yellow')
    expect(deltaColor(4)).toBe('red')
  })
  test('tools are ranked by use, MCP names shortened', () => {
    const t = new Map([['Bash', { ok: 18, failed: 1 }], ['mcp__codegraph__codegraph_explore', { ok: 2, failed: 0 }], ['Edit', { ok: 5, failed: 0 }]])
    expect(topTools(t, 2)).toEqual([['Bash', 18, 1], ['Edit', 5, 0]])
    expect(topTools(t, 3)[2]?.[0]).toBe('codegraph_explore')
  })
})

describe('heat gauges', () => {
  test('the context scale turns sooner than a plan window', () => {
    expect(heat(45, SCALE.context)).toBe(HEAT[1])
    expect(heat(45, SCALE.window)).toBe(HEAT[1])
    expect(heat(70, SCALE.context)).toBe(HEAT[3])
    expect(heat(70, SCALE.window)).toBe(HEAT[2])
    expect(heat(85, SCALE.context)).toBe(HEAT[4])
    expect(heat(10, SCALE.context)).toBe(HEAT[0])
  })
  test('a full strip runs green to red; the rest of the track is grey', () => {
    const full = heatGauge(100, 10, SCALE.window)
    expect(full.map(s => s.text).join('')).toBe('██████████')
    expect(full[0]?.color).toBe(HEAT[0])
    expect(full.at(-1)?.color).toBe(HEAT[4])
    const part = heatGauge(30, 10, SCALE.window)
    expect(part.map(s => s.text).join('')).toBe('██████████')
    expect(part.at(-1)?.color).toBe(TRACK)
    // the last filled cell moves by eighths over the track
    const smooth = heatGauge(35, 10, SCALE.window)
    expect(smooth.map(s => s.text).join('')).toBe('███▌██████')
    expect(smooth.find(s => s.text === '▌')?.backgroundColor).toBe(TRACK)
    expect(heatGauge(1, 10, SCALE.window)[0]?.text).toBe('▏')
  })
})

describe('pane helpers', () => {
  test('the countdown is green, then yellow below 40%, then red from the warning threshold', () => {
    expect(lifeColor(250_000, '5m', 60_000)).toBe('green')
    expect(lifeColor(110_000, '5m', 60_000)).toBe('yellow')
    expect(lifeColor(60_000, '5m', 60_000)).toBe('red')
    expect(lifeColor(5_000, '1h', 60_000)).toBe('red')
    expect(lifeColor(1_800_000, '1h', 60_000)).toBe('green')
  })
  test('segments sum to the width and keep small parts visible', () => {
    const s = segments(113_000, 4_000, 2, 48)
    expect(s[0] + s[1] + s[2]).toBe(48)
    expect(s[2]).toBeGreaterThanOrEqual(1)
    expect(segments(0, 0, 0, 48)).toEqual([0, 0, 0])
  })
})

describe('countdown toasts', () => {
  test('fires at the threshold, then 10, 3, 2 and 1 seconds, once each', () => {
    let level = Infinity
    const fired: number[] = []
    for (let secs = 70; secs >= 1; secs--) {
      const m = nextToastMark(secs, 60, level)
      if (m !== undefined) {
        fired.push(secs)
        level = m
      }
    }
    expect(fired).toEqual([60, 10, 3, 2, 1])
  })
  test('a stalled clock skips to the newest mark; a short warning drops the early ones', () => {
    expect(nextToastMark(2, 60, Infinity)).toBe(2)
    expect(nextToastMark(2, 60, 2)).toBeUndefined()
    expect(nextToastMark(5, 5, Infinity)).toBe(5)
    expect(nextToastMark(30, 5, Infinity)).toBeUndefined()
  })
})

describe('observed lifetime', () => {
  const prev = sample({ startedAt: T0 })
  const MIN = 60_000
  test('a hit more than 5 minutes later proves the 1-hour lifetime and sticks', () => {
    const hit = sample({ startedAt: T0 + 20 * MIN, read: 80_000, write: 500 })
    expect(observeTtl(prev, hit, undefined)).toBe('1h')
    const miss = sample({ startedAt: T0 + 40 * MIN, read: 0, write: 81_000 })
    expect(observeTtl(hit, miss, '1h')).toBe('1h')
  })
  test('a miss 5 minutes to an hour later says 5 minutes; a later hit overrules it', () => {
    const miss = sample({ startedAt: T0 + 7 * MIN, read: 0, write: 81_000 })
    expect(observeTtl(prev, miss, undefined)).toBe('5m')
    const hit = sample({ startedAt: T0 + 20 * MIN, read: 80_000, write: 500 })
    expect(observeTtl(miss, hit, '5m')).toBe('1h')
  })
  test('says nothing inside 5 minutes, across a model change, after /compact, or when nothing was cached', () => {
    expect(observeTtl(prev, sample({ startedAt: T0 + 2 * MIN, read: 0, write: 81_000 }), undefined)).toBeUndefined()
    expect(observeTtl(prev, sample({ startedAt: T0 + 20 * MIN, model: 'claude-opus-5-5', read: 0, write: 81_000 }), undefined)).toBeUndefined()
    expect(observeTtl(prev, sample({ startedAt: T0 + 20 * MIN, read: 0, write: 5_000, fresh: 100 }), undefined)).toBeUndefined()
    expect(observeTtl(sample({ read: 0, write: 0 }), sample({ startedAt: T0 + 20 * MIN }), undefined)).toBeUndefined()
    expect(observeTtl(prev, sample({ startedAt: T0 + 2 * MIN, read: 80_000 }), undefined)).toBeUndefined()
  })
})

describe('which lifetime Claude Code asks for', () => {
  test('follows the documented order: force 5m, CLAUDE_CODE_PROMPT_CACHE_TTL, setting, ENABLE_1H, account', () => {
    expect(decideTtl('auto', { force5m: '1', ttlVar: '1h' }, '1h', 'subscription').ttl).toBe('5m')
    expect(decideTtl('auto', { ttlVar: '5m', enable1h: '1' }, '1h', 'subscription')).toEqual({ ttl: '5m', source: 'CLAUDE_CODE_PROMPT_CACHE_TTL' })
    expect(decideTtl('auto', { enable1h: '1' }, '5m', 'other')).toEqual({ ttl: '5m', source: 'the promptCacheTtl setting' })
    expect(decideTtl('auto', { enable1h: '1' }, undefined, 'other').ttl).toBe('1h')
    expect(decideTtl('auto', {}, 'junk', 'subscription')).toEqual({ ttl: '1h', source: 'Claude subscription default' })
    expect(decideTtl('auto', {}, undefined, 'credits').ttl).toBe('5m')
    expect(decideTtl('auto', {}, undefined, 'other').ttl).toBe('5m')
    expect(decideTtl('1h', { force5m: '1' }, '5m', 'other').ttl).toBe('1h')
  })
  test('the account comes from the plan windows the last response reported', () => {
    expect(accountOf([])).toBe('other')
    expect(accountOf([{ kind: 'spend_limit', percentUsed: 10 }])).toBe('other')
    expect(accountOf([{ kind: 'five_hour', percentUsed: 20 }, { kind: 'seven_day', percentUsed: 5 }])).toBe('subscription')
    expect(accountOf([{ kind: 'five_hour', percentUsed: 100 }])).toBe('credits')
  })
})

describe('the GitHub quota', () => {
  test('parses remaining, limit and reset; the anonymous 60 is no account quota', () => {
    expect(parseRateLimit('4000\t5000\t1761300000\n')).toEqual({ anon: false, pct: 20, resetsAt: 1761300000000 })
    expect(parseRateLimit('55\t60\t1761300000')).toEqual({ anon: true })
    expect(parseRateLimit('')).toBeUndefined()
    expect(parseRateLimit('x\t5000\t1')).toBeUndefined()
    expect(parseRateLimit('1\t2')).toBeUndefined()
  })
})

async function settle(until: () => Promise<boolean>) {
  for (let i = 0; i < 2000 && !(await until()); i++) await Promise.resolve()
}

// the startup line comes once the first reading (and with it the account) has landed
const loaded = (calls: Calls) => settle(async () => calls.logs.some(l => l.includes('prompt-glance loaded')))

const HINT = ($: Engine) =>
  $.ui.mount({ plugin: 'prompt-glance', surface: 'terminal', component: 'PromptHint', props: { isDraft: false, isWorking: false, hint: 'bypass permissions on' } as never, viewport: { columns: 160, rows: 40 } } as never)

describe('under the prompt', () => {
  test('position below draws the HUD under the prompt with the hint after it, and the band above stays the engine\'s', { options: { position: 'below' } }, async ($, on) => {
    const calls: Calls = { status: [], logs: [] }
    fakeEngine(on, {}, calls)
    ghRate = '4000\t5000\t1761300000\n'
    // stands for the engine's own band above the prompt
    on('ui.render', ($, e) => {
      const { Text } = $.ui.resolve(e)
      return <Text>engine band</Text>
    })
    await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true } as never)
    await step($)
    const ui = await HINT($)
    await settle(async () => (await ui.find({ type: 'Text', text: /^GH/ })) !== undefined)
    expect(await ui.find({ type: 'Text', text: /^Opus 5\.5$/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /^bypass permissions on$/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /^ 20%$/ })).toBeDefined()
    await ui.unmount()
    const above = await band($)
    expect(await above.find({ type: 'Text', text: /^Opus 5\.5$/ })).toBeUndefined()
    expect(await above.find({ type: 'Text', text: /^engine band$/ })).toBeDefined()
    await above.unmount()
  })

  test('no token: GH says not logged in instead of a percentage', { options: { position: 'below' } }, async ($, on) => {
    const calls: Calls = { status: [], logs: [] }
    fakeEngine(on, {}, calls)
    ghRate = '55\t60\t1761300000\n'
    await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true } as never)
    await step($)
    const ui = await HINT($)
    await settle(async () => (await ui.find({ type: 'Text', text: /未登入/ })) !== undefined)
    expect(await ui.find({ type: 'Text', text: /^未登入$/ })).toBeDefined()
    await ui.unmount()
  })

  test('by default the hint line stays the engine\'s', async ($, on) => {
    const calls: Calls = { status: [], logs: [] }
    fakeEngine(on, {}, calls)
    // stands for the engine's own hint line
    on('ui.render', ($, e) => {
      const { Text } = $.ui.resolve(e)
      return <Text>engine hint</Text>
    })
    await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true } as never)
    await step($)
    const ui = await HINT($)
    expect(await ui.find({ type: 'Text', text: /^Opus 5\.5$/ })).toBeUndefined()
    expect(await ui.find({ type: 'Text', text: /^engine hint$/ })).toBeDefined()
    await ui.unmount()
  })
})

const PANE_PROPS = { title: 'cache', isFocused: true, bodyColumns: 60, placement: 'inline', scroll: { offset: 0, bodyRows: 40 }, view: {} }
const pane = ($: Engine, surface: 'terminal' | 'desktop' = 'terminal', bodyRows = 40, viewportRows = 40) =>
  $.ui.mount({ plugin: 'prompt-glance', surface, component: 'Pane', requestId: 'cache', props: { ...PANE_PROPS, scroll: { offset: 0, bodyRows } } as never, viewport: { columns: 100, rows: viewportRows } } as never)
const wide = ($: Engine, props: Record<string, unknown> = {}) =>
  $.ui.mount({ plugin: 'prompt-glance', surface: 'terminal', component: 'AbovePrompt', props: { hasSurvey: false, bodyColumns: 160, ...props } as never })
const START = { cwd: '/repo', surface: 'terminal', isInteractive: true } as never
const END = (reason: string) => ({ reason, sessionId: 's1', resume: {} }) as never
// stands for the engine's own drawing under the plugin
const engineDraws = (on: On) =>
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine</Text>
  })

describe('turns and subagents', () => {
  test('a subagent starting mid-turn leaves the main turn\'s baseline alone', async ($, on) => {
    const calls: Calls = { status: [], logs: [] }
    const money = { usd: 1.2 }
    fakeEngine(on, {}, calls, undefined, [], money)
    await $.session.start(START)
    await $.turn.start({ text: 'hi', turnId: 't1' } as never)
    money.usd = 1.5
    // the main loop's first request lands, and with it the $1.50 the turn has spent so far, before the subagent starts
    await step($)
    const before = await wide($)
    await settle(async () => (await before.find({ type: 'Text', text: /^\$1\.50$/ })) !== undefined)
    expect(await before.find({ type: 'Text', text: /^\$0\.30$/ })).toBeDefined()
    await before.unmount()
    await $.turn.start({ text: 'go', turnId: 't2', agentId: 'a1' } as never)
    money.usd = 1.62
    await step($, { index: 1 })
    const ui = await wide($)
    await settle(async () => (await ui.find({ type: 'Text', text: /^\$1\.62$/ })) !== undefined)
    expect(await ui.find({ type: 'Text', text: /^\$0\.42$/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /^\$0\.12$/ })).toBeUndefined()
    await ui.unmount()
  })

  test('a reading that lands late, across a turn boundary, does not skew the next turn', async ($, on) => {
    const calls: Calls = { status: [], logs: [] }
    const money = { usd: 1.2 }
    fakeEngine(on, {}, calls, undefined, [], money)
    await $.session.start(START)
    await $.turn.start({ text: 'hi', turnId: 't1' } as never)
    money.usd = 1.5
    // the reading after the first turn's request is slow: it is still out when the next turn starts
    let release = () => {}
    usageHold = new Promise<void>(r => (release = r))
    await step($)
    await $.turn.start({ text: 'again', turnId: 't2' } as never)
    money.usd = 1.62
    await step($, { turnId: 't2' })
    // and lands last, with the $1.50 it read: the newer reading stands
    release()
    await settle(async () => usageHeldOut)
    for (let i = 0; i < 50; i++) await Promise.resolve()
    const ui = await wide($)
    await settle(async () => (await ui.find({ type: 'Text', text: /^\$1\.62$/ })) !== undefined)
    expect(await ui.find({ type: 'Text', text: /^\$1\.62$/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /^\$0\.12$/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /^\$0\.42$/ })).toBeUndefined()
    await ui.unmount()
  })
})

describe('a new conversation in the same process', () => {
  test('/clear starts the meter and the activity over', async ($, on) => {
    const calls: Calls = { status: [], logs: [] }
    fakeEngine(on, {}, calls)
    on('tool.call', async () => ({ result: 'ok' }) as never)
    await $.session.start(START)
    await step($)
    await $.tool.call({ tool: 'Bash', command: 'ls' } as never)
    await $.session.end(END('clear'))
    const ui = await wide($)
    expect(await ui.find({ type: 'Text', text: /waiting for first request/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /^  hit $/ })).toBeUndefined()
    expect(await ui.find({ type: 'Text', text: /^Bash$/ })).toBeUndefined()
    await ui.unmount()
  })

  test('/clear of an expensive conversation: the next turn shows what it spent, not the old total', async ($, on) => {
    const calls: Calls = { status: [], logs: [] }
    const money = { usd: 4.8 }
    fakeEngine(on, {}, calls, undefined, [], money)
    await $.session.start(START)
    await $.turn.start({ text: 'hi', turnId: 't1' } as never)
    money.usd = 5
    await step($)
    const old = await wide($)
    await settle(async () => (await old.find({ type: 'Text', text: /^\$5\.00$/ })) !== undefined)
    await old.unmount()
    // a reading taken as the conversation ends still sees the old $5, and is slow to land
    let release = () => {}
    usageHold = new Promise<void>(r => (release = r))
    await $.session.end(END('clear'))
    // the new conversation counts from zero, and its first prompt comes before that reading lands
    money.usd = 0
    await $.turn.start({ text: 'new', turnId: 't2' } as never)
    money.usd = 0.2
    await step($, { turnId: 't2' })
    release()
    await settle(async () => usageHeldOut)
    for (let i = 0; i < 50; i++) await Promise.resolve()
    const ui = await wide($)
    await settle(async () => (await ui.find({ type: 'Text', text: /^\$0\.20$/ })) !== undefined)
    expect(await ui.find({ type: 'Text', text: /^Turn $/ })).toBeDefined()
    // the turn and the session both spent $0.20
    expect((await ui.findAll({ type: 'Text', text: /^\$0\.20$/ })).length).toBe(2)
    expect(await ui.find({ type: 'Text', text: /^\$0\.00$/ })).toBeUndefined()
    await ui.unmount()
  })

  test('a resume starts the meter over and the clock keeps ticking', { options: { status: true } }, async ($, on) => {
    const calls: Calls = { status: [], logs: [] }
    const clock = mock.clock(on, { now: Date.now() })
    fakeEngine(on, {}, calls, undefined, [], undefined, { clock: false })
    await $.session.start(START)
    await step($)
    await clock.advance(1000)
    expect(calls.status.at(-1)).toMatch(/^cache 98%/)
    await $.session.end(END('resume'))
    await clock.advance(1000)
    // the old conversation's request is gone, and the tick says so
    expect(calls.status.at(-1)).toMatch(/^cache: no request yet/)
    // and still runs: a /model switch shows within a second, with no request
    modelId = 'claude-sonnet-5-5'
    await clock.advance(1000)
    const ui = await wide($)
    expect(await ui.find({ type: 'Text', text: /^Sonnet 5\.5$/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /^  hit $/ })).toBeUndefined()
    await ui.unmount()
  })
})

describe('session figures beyond the last 200 requests', () => {
  test('the hit rate and the misses count every request of the conversation, not just the samples kept', async ($, on) => {
    const calls: Calls = { status: [], logs: [] }
    const cache = { read: 0, write: 100_000 }
    fakeEngine(on, {}, calls, cache)
    await $.session.start(START)
    // the first request writes the prefix; three more write it again: three misses
    for (let i = 1; i <= 4; i++) await step($, { turnId: `t${i}` })
    // then 210 hits push those four out of the 200 kept
    cache.read = 100_000
    cache.write = 0
    for (let i = 5; i <= 214; i++) await step($, { turnId: `t${i}` })
    const ui = await wide($)
    // 21M read of 214 × 100,300 prompt tokens: 97.8%, where the last 200 alone say 99.7%
    expect(await ui.find({ type: 'Text', text: /^97%$/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /^99\.7%$/ })).toBeUndefined()
    expect(await ui.find({ type: 'Text', text: /^  misses $/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /^3$/ })).toBeDefined()
    await ui.unmount()
    // /clear starts the totals over
    await $.session.end(END('clear'))
    await step($, { turnId: 'n1' })
    const after = await wide($)
    expect(await after.find({ type: 'Text', text: /^99\.7%$/ })).toBeDefined()
    expect(await after.find({ type: 'Text', text: /^  misses $/ })).toBeUndefined()
    await after.unmount()
  })
})

describe('nothing waits on git', () => {
  test('a slow git status holds no hook; the band draws what it has, the branch when git answers', async ($, on) => {
    const calls: Calls = { status: [], logs: [] }
    const clock = mock.clock(on, { now: Date.now() })
    fakeEngine(on, {}, calls, undefined, [], { usd: 0.5 }, { clock: false })
    // git takes 8 seconds to answer
    gitRun = () => clock.sleep(8_000).then(() => ({ value: { exitCode: 0, stdout: '## main\n', stderr: '' } }))
    await $.session.start(START)
    await $.turn.start({ text: 'hi', turnId: 't1' } as never)
    await step($)
    const ui = await wide($)
    expect(await ui.find({ type: 'Text', text: /^Opus 5\.5$/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /^Session $/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /^main$/ })).toBeUndefined()
    await ui.unmount()
    await clock.advance(8_000)
    const later = await wide($)
    expect(await later.find({ type: 'Text', text: /^main$/ })).toBeDefined()
    await later.unmount()
  })

  test('git status runs without the optional index lock', async ($, on) => {
    const calls: Calls = { status: [], logs: [] }
    fakeEngine(on, {}, calls)
    await $.session.start(START)
    await settle(async () => argvs.some(a => a.includes('status')))
    const git = argvs.find(a => a.includes('status'))
    expect(git?.slice(0, 3)).toEqual(['git', '--no-optional-locks', 'status'])
  })
})

describe('the GitHub gauge', () => {
  test('gh never logged in says 未登入', { options: { position: 'below' } }, async ($, on) => {
    const calls: Calls = { status: [], logs: [] }
    fakeEngine(on, {}, calls)
    ghRate = ''
    ghExit = { exitCode: 4, stderr: 'To get started with GitHub CLI, please run:  gh auth login\n' }
    await $.session.start(START)
    await step($)
    const ui = await HINT($)
    await settle(async () => (await ui.find({ type: 'Text', text: /未登入/ })) !== undefined)
    expect(await ui.find({ type: 'Text', text: /^未登入$/ })).toBeDefined()
    await ui.unmount()
  })

  test('a failed refresh marks the reading stale, and drops it once its window has reset', { options: { position: 'below' } }, async ($, on) => {
    const calls: Calls = { status: [], logs: [] }
    const clock = mock.clock(on, { now: Date.now() })
    fakeEngine(on, {}, calls, undefined, [], undefined, { clock: false })
    const soon = Math.ceil(Date.now() / 1000) + 3600
    ghRate = `4000\t5000\t${soon}\n`
    await $.session.start(START)
    await step($)
    const ui = await HINT($)
    await settle(async () => (await ui.find({ type: 'Text', text: /^ 20%$/ })) !== undefined)
    expect(await ui.find({ type: 'Text', text: /^ 20%$/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /^ \?$/ })).toBeUndefined()
    // the next refresh fails: the reading stays, marked as old
    await ui.unmount()
    ghExit = { exitCode: 1, stderr: 'error connecting to api.github.com\n' }
    await clock.advance(120_000)
    const later = await HINT($)
    expect(await later.find({ type: 'Text', text: /^ 20%$/ })).toBeDefined()
    expect(await later.find({ type: 'Text', text: /^ \?$/ })).toBeDefined()
    await later.unmount()
  })

  test('a stale reading whose window has reset is not drawn', { options: { position: 'below' } }, async ($, on) => {
    const calls: Calls = { status: [], logs: [] }
    const clock = mock.clock(on, { now: Date.now() })
    fakeEngine(on, {}, calls, undefined, [], undefined, { clock: false })
    ghRate = `4000\t5000\t${Math.floor(Date.now() / 1000) - 1}\n`
    await $.session.start(START)
    await step($)
    const ui = await HINT($)
    await settle(async () => (await ui.find({ type: 'Text', text: /^ 20%$/ })) !== undefined)
    expect(await ui.find({ type: 'Text', text: /^ 20%$/ })).toBeDefined()
    await ui.unmount()
    ghExit = { exitCode: 1, stderr: 'timeout\n' }
    await clock.advance(120_000)
    const later = await HINT($)
    expect(await later.find({ type: 'Text', text: /^GH/ })).toBeUndefined()
    await later.unmount()
  })
})

describe('the clock', () => {
  test('a large prompt toasts at the warning threshold', { options: { warnSeconds: 300 } }, async ($, on) => {
    const calls: Calls = { status: [], logs: [], toasts: [] }
    const clock = mock.clock(on, { now: Date.now() })
    fakeEngine(on, {}, calls, undefined, [], undefined, { clock: false })
    await $.session.start(START)
    await step($)
    await clock.advance(1000)
    expect(calls.toasts).toEqual([expect.stringMatching(/^cache expires in [45]:\d\d: send a message to keep 81\.3k tokens warm$/)])
    // once per mark: the next tick says nothing new
    await clock.advance(1000)
    expect(calls.toasts?.length).toBe(1)
  })

  test('a small prompt never toasts', { options: { warnSeconds: 300 } }, async ($, on) => {
    const calls: Calls = { status: [], logs: [], toasts: [] }
    const clock = mock.clock(on, { now: Date.now() })
    fakeEngine(on, {}, calls, { read: 10_000, write: 500 }, [], undefined, { clock: false })
    await $.session.start(START)
    await step($)
    await clock.advance(3000)
    expect(calls.toasts).toEqual([])
  })

  test('the tick redraws the status line and a /model switch with no request', { options: { status: true } }, async ($, on) => {
    const calls: Calls = { status: [], logs: [] }
    const clock = mock.clock(on, { now: Date.now() })
    fakeEngine(on, {}, calls, undefined, [], undefined, { clock: false })
    await $.session.start(START)
    await clock.advance(1000)
    expect(calls.status).toEqual([expect.stringMatching(/^cache: no request yet/)])
    modelId = 'claude-haiku-4-5'
    await clock.advance(1000)
    const ui = await wide($)
    expect(await ui.find({ type: 'Text', text: /^Haiku 4\.5$/ })).toBeDefined()
    await ui.unmount()
  })

  test('a hit 20 minutes after the last request switches the lifetime to the observed hour', async ($, on) => {
    const calls: Calls = { status: [], logs: [] }
    // the clock the requests are timed by: the first 20 minutes ago, the second now
    let at = Date.now() - 20 * 60_000
    on('clock.now', () => ({ value: at }) as never)
    fakeEngine(on, {}, calls)
    on('command.run', () => ({ text: '' }) as never)
    await $.session.start(START)
    await step($)
    at = Date.now()
    await step($, { turnId: 't2' })
    const reply = await $.command.run({ command: 'cache', args: '' } as never)
    expect((reply as { text: string }).text).toMatch(/^1h cache \(observed from request timing; default said 5m\)/)
  })
})

describe('/cache', () => {
  test('opens the pane, which takes the band\'s place; stop closes it and the band comes back', async ($, on) => {
    const calls: Calls = { status: [], logs: [] }
    fakeEngine(on, {}, calls)
    on('command.run', () => ({ text: '' }) as never)
    engineDraws(on)
    await $.session.start(START)
    await step($)
    await step($, { turnId: 't2' })
    await step($, { turnId: 't2', index: 1 })
    const reply = await $.command.run({ command: 'cache', args: '' } as never)
    expect((reply as { text: string }).text).toMatch(/^5m cache \(default\) · .* · \/cache stop closes$/)
    const yielded = await wide($)
    expect(await yielded.find({ type: 'Text', text: /^engine$/ })).toBeDefined()
    expect(await yielded.find({ type: 'Text', text: /^Opus 5\.5$/ })).toBeUndefined()
    await yielded.unmount()

    for (const surface of ['terminal', 'desktop'] as const) {
      const ui = await pane($, surface)
      expect(await ui.find({ type: 'Text', text: /PROMPT.CACHE/ })).toBeDefined()
      // a row per turn: the second turn's two requests summed
      expect(await ui.find({ key: 't:t1' })).toBeDefined()
      expect((await ui.findAll({ type: 'Text', in: undefined })).some(t => t.text === '2')).toBe(true)
      expect(await ui.find({ type: 'Button', key: 'close' })).toBeDefined()
      await ui.unmount()
    }

    await $.command.run({ command: 'cache', args: 'stop' } as never)
    const back = await wide($)
    expect(await back.find({ type: 'Text', text: /^Opus 5\.5$/ })).toBeDefined()
    await back.unmount()
  })

  test('the close button closes the pane and the band comes back', async ($, on) => {
    const calls: Calls = { status: [], logs: [], closed: [] }
    fakeEngine(on, {}, calls)
    on('command.run', () => ({ text: '' }) as never)
    await $.session.start(START)
    await step($)
    await $.command.run({ command: 'cache', args: '' } as never)
    const ui = await pane($)
    await ui.press({ key: 'close' })
    await ui.unmount()
    expect(calls.closed).toEqual(['cache'])
    const back = await wide($)
    expect(await back.find({ type: 'Text', text: /^Opus 5\.5$/ })).toBeDefined()
    await back.unmount()
  })

  test('the table takes the pane\'s own rows, numbering turns from the session\'s first', async ($, on) => {
    const calls: Calls = { status: [], logs: [] }
    fakeEngine(on, {}, calls)
    await $.session.start(START)
    for (let i = 1; i <= 205; i++) await step($, { turnId: `t${i}` })
    // a tall terminal, a short pane: the pane's room decides
    const ui = await pane($, 'terminal', 26, 60)
    expect(await ui.find({ key: 't:t205' })).toBeDefined()
    expect(await ui.find({ key: 't:t190' })).toBeUndefined()
    const last = await ui.find({ key: 'c:turn:t205' })
    expect(last?.text).toBe('205')
    await ui.unmount()
  })
})

describe('the band gives way', () => {
  test('to a survey', async ($, on) => {
    const calls: Calls = { status: [], logs: [] }
    fakeEngine(on, {}, calls)
    engineDraws(on)
    await $.session.start(START)
    await step($)
    const ui = await wide($, { hasSurvey: true })
    expect(await ui.find({ type: 'Text', text: /^engine$/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /^Opus 5\.5$/ })).toBeUndefined()
    await ui.unmount()
  })

  test('to nothing at all when the band is off, above or below', { options: { band: false } }, async ($, on) => {
    const calls: Calls = { status: [], logs: [] }
    fakeEngine(on, {}, calls)
    engineDraws(on)
    await $.session.start(START)
    await step($)
    for (const ui of [await wide($), await HINT($)]) {
      expect(await ui.find({ type: 'Text', text: /^engine$/ })).toBeDefined()
      expect(await ui.find({ type: 'Text', text: /^Opus 5\.5$/ })).toBeUndefined()
      await ui.unmount()
    }
  })
})

describe('the activity and the windows', () => {
  test('a failed tool call counts as failed; a skill shows under Skills, not Tools', async ($, on) => {
    const calls: Calls = { status: [], logs: [] }
    fakeEngine(on, {}, calls)
    on('tool.call', async ($, e) => ((e as { command?: string }).command === 'false' ? { result: 'exit 1', isError: true } : { result: 'ok' }) as never)
    await $.session.start(START)
    await step($)
    await $.tool.call({ tool: 'Bash', command: 'ls' } as never)
    await $.tool.call({ tool: 'Bash', command: 'false' } as never)
    await $.tool.call({ tool: 'Skill', skill: 'tdd' } as never)
    const ui = await wide($)
    expect(await ui.find({ type: 'Text', text: /^×2$/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /^  ✗1$/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /^(  )?Skill$/ })).toBeUndefined()
    expect(await ui.find({ type: 'Text', text: /^tdd$/ })).toBeDefined()
    await ui.unmount()
  })

  test('only a window past half shows when it resets', async ($, on) => {
    const calls: Calls = { status: [], logs: [] }
    const at = (h: number) => new Date(Date.now() + h * 3600_000).toISOString()
    fakeEngine(on, {}, calls, undefined, [
      { kind: 'five_hour', percentUsed: 72, resetsAt: at(3) },
      { kind: 'seven_day', percentUsed: 3, resetsAt: at(100) },
    ])
    await $.session.start(START)
    await step($)
    const ui = await wide($, { bodyColumns: 150 })
    await settle(async () => (await ui.find({ type: 'Text', text: /^ 72%$/ })) !== undefined)
    expect((await ui.findAll({ type: 'Text', text: /↻/ })).map(t => t.text)).toEqual([' ↻3h'])
    await ui.unmount()
  })
})

describe('the promptCacheTtl setting', () => {
  // the engine's merged settings (policy, --settings, CLAUDE_CONFIG_DIR's user file and the rest), not files the mod picks
  const settingsSay = (on: On, answer: () => unknown) => on('settings.read', () => answer() as never)

  test('the merged settings decide, over the subscription default', async ($, on) => {
    const calls: Calls = { status: [], logs: [] }
    fakeEngine(on, {}, calls, undefined, [{ kind: 'five_hour', percentUsed: 12 }])
    settingsSay(on, () => ({ value: { promptCacheTtl: '5m' } }))
    await $.session.start(START)
    await loaded(calls)
    expect(calls.logs.join('\n')).toContain('5m cache (the promptCacheTtl setting)')
  })

  test('1h from the settings beats the usage-credits default', async ($, on) => {
    const calls: Calls = { status: [], logs: [] }
    fakeEngine(on, {}, calls, undefined, [{ kind: 'five_hour', percentUsed: 100 }])
    settingsSay(on, () => ({ value: { promptCacheTtl: '1h' } }))
    await $.session.start(START)
    await loaded(calls)
    expect(calls.logs.join('\n')).toContain('1h cache (the promptCacheTtl setting)')
  })

  test('the environment variable still beats the setting', async ($, on) => {
    const calls: Calls = { status: [], logs: [] }
    fakeEngine(on, { CLAUDE_CODE_PROMPT_CACHE_TTL: '1h' }, calls)
    settingsSay(on, () => ({ value: { promptCacheTtl: '5m' } }))
    await $.session.start(START)
    await loaded(calls)
    expect(calls.logs.join('\n')).toContain('1h cache (CLAUDE_CODE_PROMPT_CACHE_TTL)')
  })

  test('a value other than 5m or 1h is no setting', async ($, on) => {
    const calls: Calls = { status: [], logs: [] }
    fakeEngine(on, {}, calls, undefined, [{ kind: 'five_hour', percentUsed: 12 }])
    settingsSay(on, () => ({ value: { promptCacheTtl: '10m' } }))
    await $.session.start(START)
    await loaded(calls)
    expect(calls.logs.join('\n')).toContain('1h cache (Claude subscription default)')
  })

  test('a settings read that fails leaves the default', async ($, on) => {
    const calls: Calls = { status: [], logs: [] }
    fakeEngine(on, {}, calls, undefined, [{ kind: 'five_hour', percentUsed: 12 }])
    settingsSay(on, () => ({ deny: 'settings unreadable' }))
    await $.session.start(START)
    await loaded(calls)
    expect(calls.logs.join('\n')).toContain('1h cache (Claude subscription default)')
  })
})
