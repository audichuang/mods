import { expect, mock, test } from 'claude-code/testing'

const FILE = '/home/u/.local/state/gh-quota/meter.log'
const JQ = '[.resources.core.remaining, .resources.core.limit, .resources.core.reset, .resources.graphql.remaining] | @tsv'

type Out = { exitCode: number; stdout: string; stderr?: string } | 'reject'

// Stands in for the engine: gh answers `out` to rate_limit (a list is one answer per call, the
// last repeating), files live in `files`. `noVersion` lists the binaries whose `--version` probe
// fails. With `clock` the periods run on mock.clock, moved by the test; without, only start-up.
function engine(on: any, out: Out | Out[], opts: { clock?: boolean; noVersion?: string[] } = {}) {
  const files: Record<string, string> = {}
  const calls = { status: [] as (string | undefined)[], toast: [] as string[], every: 0, runs: [] as { argv: readonly string[]; cwd?: string }[] }
  const answers = Array.isArray(out) ? out : [out]
  let asked = 0
  on('session.start', (_: unknown, e: { cwd: string }) => ({ cwd: e.cwd }))
  on('env.get', () => ({ value: '/home/u' }))
  on('fs.read', (_: unknown, e: { path: string }) => {
    if (!(e.path in files)) throw new Error('ENOENT')
    return { value: files[e.path] }
  })
  on('fs.write', (_: unknown, e: { path: string; text: string }) => {
    files[e.path] = e.text
    return { value: undefined }
  })
  on('process.run', (_: unknown, e: { argv: readonly string[]; init?: { cwd?: string } }) => {
    calls.runs.push({ argv: e.argv, cwd: e.init?.cwd })
    if (e.argv[1] === '--version') {
      if (opts.noVersion?.includes(e.argv[0] ?? '')) throw new Error('ENOENT')
      return { value: { exitCode: 0, stdout: 'gh version 2', stderr: '' } }
    }
    const answer = answers[Math.min(asked++, answers.length - 1)]!
    if (answer === 'reject') throw new Error('timed out')
    return { value: { stderr: '', ...answer } }
  })
  on('ui.status', (_: unknown, e: { text?: string }) => {
    calls.status.push(e.text)
    return { value: undefined }
  })
  on('ui.toast', (_: unknown, e: { text: string }) => {
    calls.toast.push(e.text)
    return { value: undefined }
  })
  if (opts.clock) return { files, calls, clock: mock.clock(on) }
  // Each { value } is one elapsed period; refusing the first keeps the test to the start-up check.
  on('clock.every', () => {
    calls.every++
    return { deny: 'test' }
  })
  return { files, calls, clock: undefined }
}

const kinds = (log: string | undefined) => (log ?? '').trim().split('\n').map(l => l.split('\t')[1])

async function settle(until: () => boolean) {
  // The environment has no timers; yielding lets the start-up refresh's $ calls run through.
  for (let i = 0; i < 5000 && !until(); i++) await Promise.resolve()
}

test('interactive session: status shows the quota, log has start then ok', { options: { status: true } }, async ($, on) => {
  const { files, calls } = engine(on, { exitCode: 0, stdout: '4200\t5000\t1761300000\t4900\n' })
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true } as any)
  await settle(() => calls.status.length > 0 && (files[FILE] ?? '').includes('\tok\t'))
  expect(calls.status.at(-1)).toMatch(/^GH 4200\/5000 · GQL 4900 · \d\d:\d\d 重置$/)
  const lines = (files[FILE] ?? '').trim().split('\n').map(l => l.split('\t')[1])
  expect(lines).toEqual(['start', 'ok'])
  expect(calls.every).toBe(1)
  expect(calls.toast).toEqual([])
})

test('low quota: one toast and a warn line', async ($, on) => {
  const { files, calls } = engine(on, { exitCode: 0, stdout: '300\t5000\t1761300000\t4900\n' })
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true } as any)
  await settle(() => calls.toast.length > 0 && (files[FILE] ?? '').includes('\tok\t'))
  expect(calls.toast).toHaveLength(1)
  expect(files[FILE]).toContain('\twarn\t300/5000')
})

test('anonymous quota: says not logged in, no toast', { options: { status: true } }, async ($, on) => {
  const { files, calls } = engine(on, { exitCode: 0, stdout: '55\t60\t1761300000\t0\n' })
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true } as any)
  await settle(() => (files[FILE] ?? '').includes('\tanon\t'))
  expect(calls.status.at(-1)).toBe('GH 未登入（匿名 55/60）· gh auth login')
  expect(calls.toast).toEqual([])
  expect((files[FILE] ?? '').trim().split('\n').map(l => l.split('\t')[1])).toEqual(['start', 'anon'])
})

test('timeout is told apart from a failed call', { options: { status: true } }, async ($, on) => {
  const { files, calls } = engine(on, 'reject')
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true } as any)
  await settle(() => (files[FILE] ?? '').includes('\ttimeout\t'))
  expect(calls.status.at(-1)).toBe('GH 額度：查詢逾時')
})

test('non-interactive session: no polling, no log', async ($, on) => {
  const { files, calls } = engine(on, { exitCode: 0, stdout: '4200\t5000\t1761300000\t4900\n' })
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: false } as any)
  await settle(() => false)
  expect(calls.every).toBe(0)
  expect(files).toEqual({})
})

test('by default no status entry: the log and the toast still work', async ($, on) => {
  const { files, calls } = engine(on, { exitCode: 0, stdout: '300\t5000\t1761300000\t4900\n' })
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true } as any)
  await settle(() => calls.toast.length > 0 && (files[FILE] ?? '').includes('\tok\t'))
  // only the clearing of what an earlier version pinned, never a text
  expect(calls.status).toEqual([undefined])
  expect(files[FILE]).toContain('\twarn\t300/5000')
})

test('warns once per reset window across refreshes, again when the reset changes', async ($, on) => {
  const low = (reset: number) => ({ exitCode: 0, stdout: `300\t5000\t${reset}\t4900\n` })
  const { files, calls, clock } = engine(on, [low(1761300000), low(1761300000), low(1761300000), low(1761303600)], { clock: true })
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true } as any)
  await clock!.settle()
  await clock!.advance(120_000)
  await clock!.advance(120_000)
  expect(calls.toast).toHaveLength(1)
  await clock!.advance(120_000)
  expect(calls.runs.filter(r => r.argv[1] === 'api')).toHaveLength(4)
  expect(calls.toast).toHaveLength(2)
  expect(kinds(files[FILE])).toEqual(['start', 'warn', 'ok', 'warn'])
})

test('a kind change is logged each time it changes, a repeat is not', async ($, on) => {
  const ok = { exitCode: 0, stdout: '4200\t5000\t1761300000\t4900\n' }
  const { files, clock } = engine(on, [ok, ok, 'reject', ok], { clock: true })
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true } as any)
  await clock!.settle()
  for (let i = 0; i < 3; i++) await clock!.advance(120_000)
  expect(kinds(files[FILE])).toEqual(['start', 'ok', 'timeout', 'ok'])
})

test('gh is asked for rate_limit with the expected jq, in HOME not the session cwd', async ($, on) => {
  const { files, calls } = engine(on, { exitCode: 0, stdout: '4200\t5000\t1761300000\t4900\n' })
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true } as any)
  await settle(() => (files[FILE] ?? '').includes('\tok\t'))
  expect(calls.runs.map(r => r.argv)).toEqual([['gh', '--version'], ['gh', 'api', 'rate_limit', '--jq', JQ]])
  // a deleted session cwd (a removed worktree) would make every spawn fail
  expect(calls.runs.map(r => r.cwd)).toEqual(['/home/u', '/home/u'])
})

test('gh never logged in (exit 4) says not logged in, not a failure', { options: { status: true } }, async ($, on) => {
  const { files, calls } = engine(on, { exitCode: 4, stdout: '', stderr: 'To get started with GitHub CLI, please run:  gh auth login\n' })
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true } as any)
  await settle(() => kinds(files[FILE]).length >= 2)
  expect(kinds(files[FILE])).toEqual(['start', 'anon'])
  expect(calls.status.at(-1)).toBe('GH 未登入 · gh auth login')
  expect(calls.toast).toEqual([])
})

test('a failed call (exit 1, HTTP 401) is fail with its stderr', { options: { status: true } }, async ($, on) => {
  const { files, calls } = engine(on, { exitCode: 1, stdout: '', stderr: 'gh: Bad credentials (HTTP 401)\n' })
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true } as any)
  await settle(() => kinds(files[FILE]).length >= 2)
  expect(kinds(files[FILE])).toEqual(['start', 'fail'])
  expect(files[FILE]).toContain('\tfail\texit 1: gh: Bad credentials (HTTP 401)')
  expect(calls.status.at(-1)).toBe('GH 額度：查詢失敗')
})

for (const stdout of ['', '1\t2\t3', '\t5000\t1\t1', 'x\t5000\t1\t1']) {
  test(`bad output ${JSON.stringify(stdout)}: bad-output, no toast`, { options: { status: true } }, async ($, on) => {
    const { files, calls } = engine(on, { exitCode: 0, stdout })
    await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true } as any)
    await settle(() => kinds(files[FILE]).length >= 2)
    expect(kinds(files[FILE])).toEqual(['start', 'bad-output'])
    expect(calls.status.at(-1)).toBe('GH 額度：回應格式不對')
    expect(calls.toast).toEqual([])
  })
}

test('no gh anywhere: no-gh, rate_limit never asked', { options: { status: true } }, async ($, on) => {
  const all = ['gh', '/opt/homebrew/bin/gh', '/home/linuxbrew/.linuxbrew/bin/gh', '/usr/local/bin/gh', '/usr/bin/gh']
  const { files, calls } = engine(on, { exitCode: 0, stdout: '4200\t5000\t1761300000\t4900\n' }, { noVersion: all })
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true } as any)
  await settle(() => kinds(files[FILE]).length >= 2)
  expect(kinds(files[FILE])).toEqual(['start', 'no-gh'])
  expect(calls.status.at(-1)).toBe('GH 額度：找不到 gh')
  expect(calls.runs.every(r => r.argv[1] === '--version')).toBe(true)
})

test('gh off PATH: falls back to the Homebrew path', async ($, on) => {
  const { files, calls } = engine(on, { exitCode: 0, stdout: '4200\t5000\t1761300000\t4900\n' }, { noVersion: ['gh'] })
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true } as any)
  await settle(() => (files[FILE] ?? '').includes('\tok\t'))
  expect(calls.runs.at(-1)?.argv[0]).toBe('/opt/homebrew/bin/gh')
})
