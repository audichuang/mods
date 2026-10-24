import { expect, test } from 'claude-code/testing'

const FILE = '/home/u/.local/state/gh-quota/meter.log'

// Stands in for the engine: gh answers `out` to rate_limit, files live in `files`.
function engine(on: any, out: { exitCode: number; stdout: string; stderr?: string } | 'reject') {
  const files: Record<string, string> = {}
  const calls = { status: [] as (string | undefined)[], toast: [] as string[], every: 0 }
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
  on('process.run', (_: unknown, e: { argv: string[] }) => {
    if (e.argv[1] === '--version') return { value: { exitCode: 0, stdout: 'gh version 2', stderr: '' } }
    if (out === 'reject') throw new Error('timed out')
    return { value: { stderr: '', ...out } }
  })
  on('ui.status', (_: unknown, e: { text?: string }) => {
    calls.status.push(e.text)
    return { value: undefined }
  })
  on('ui.toast', (_: unknown, e: { text: string }) => {
    calls.toast.push(e.text)
    return { value: undefined }
  })
  // Each { value } is one elapsed period; refusing the first keeps the test to the start-up check.
  on('clock.every', () => {
    calls.every++
    return { deny: 'test' }
  })
  return { files, calls }
}

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
  expect(calls.status).toEqual([])
  expect(files[FILE]).toContain('\twarn\t300/5000')
})
