import type { Register } from 'claude-code'

// The rate_limit endpoint itself does not count against the quota.
const EVERY_MS = 120_000
const WARN_BELOW = 1000
const JQ = '[.resources.core.remaining, .resources.core.limit, .resources.core.reset, .resources.graphql.remaining] | @tsv'
// $.process.run takes no shell, and the Claude process's PATH may lack Homebrew's bin.
const GH = ['gh', '/opt/homebrew/bin/gh', '/home/linuxbrew/.linuxbrew/bin/gh', '/usr/local/bin/gh', '/usr/bin/gh'] as const
// Shared with the gh-quota hook's hook.log; one line per state change, newest LOG_MAX kept.
const LOG_DIR = '.local/state/gh-quota'
const LOG_MAX = 500

type Kind = 'ok' | 'no-gh' | 'timeout' | 'fail' | 'bad-output'

export const register: Register = on => {
  let warnedForReset = 0
  let gh: string | undefined
  let lastKind: Kind | undefined

  on('session.start', async ($, e, next) => {
    // Nobody sees a status line in -p or SDK runs.
    if (!e.isInteractive) {
      return next(e)
    }

    // $.fs.write replaces the whole file, so append by rewriting the tail.
    const log = async (event: string, detail: string) => {
      const home = await $.env.get('HOME')
      if (home === undefined) {
        return
      }
      const path = `${home}/${LOG_DIR}/meter.log`
      const before = await $.fs.read(path).catch(() => '')
      const line = `${new Date().toISOString()}\t${event}\t${detail}`
      const kept = [...before.split('\n').filter(l => l !== ''), line].slice(-LOG_MAX)
      await $.fs.write(path, kept.join('\n') + '\n').catch(() => undefined)
    }

    // run() rejects both when the binary can't start and when it outlives timeoutMs, so find
    // gh with an offline `--version` first; a rejected rate_limit call then means a timeout.
    const findGh = async () => {
      for (const bin of GH) {
        const ran = await $.process.run([bin, '--version'], { timeoutMs: 5_000 }).catch(() => undefined)
        if (ran?.exitCode === 0) {
          return bin
        }
      }
      return undefined
    }

    const check = async (): Promise<{ kind: Kind; text: string; detail: string }> => {
      gh ??= await findGh()
      if (gh === undefined) {
        return { kind: 'no-gh', text: 'GH 額度：找不到 gh', detail: GH.join(' ') }
      }
      const ran = await $.process.run([gh, 'api', 'rate_limit', '--jq', JQ], { timeoutMs: 15_000 }).catch(() => undefined)
      if (ran === undefined) {
        return { kind: 'timeout', text: 'GH 額度：查詢逾時', detail: gh }
      }
      if (ran.exitCode !== 0) {
        return { kind: 'fail', text: 'GH 額度：查詢失敗', detail: `exit ${ran.exitCode}: ${ran.stderr.trim().slice(0, 200)}` }
      }
      // Number('') is 0, so reject empty fields before converting.
      const fields = ran.stdout.trim().split('\t')
      const [remaining, limit, reset, graphql] = fields.map(Number)
      if (fields.length !== 4 || fields.includes('') || remaining === undefined || limit === undefined || reset === undefined || graphql === undefined || [remaining, limit, reset, graphql].some(Number.isNaN)) {
        return { kind: 'bad-output', text: 'GH 額度：回應格式不對', detail: ran.stdout.trim().slice(0, 200) }
      }
      const resetAt = new Date(reset * 1000).toTimeString().slice(0, 5)
      if (remaining < WARN_BELOW && warnedForReset !== reset) {
        warnedForReset = reset
        $.ui.toast(`GitHub API 額度只剩 ${remaining}/${limit}，${resetAt} 重置。等 CI 用 gh-wait，別輪詢。`)
        await log('warn', `${remaining}/${limit} reset ${resetAt}`)
      }
      return { kind: 'ok', text: `GH ${remaining}/${limit} · GQL ${graphql} · ${resetAt} 重置`, detail: `${remaining}/${limit} gql ${graphql}` }
    }

    const refresh = async () => {
      const state = await check()
      $.ui.status(state.text)
      if (state.kind !== lastKind) {
        lastKind = state.kind
        await log(state.kind, state.detail)
      }
    }

    await log('start', e.cwd)
    // Don't hold the session start on a network call.
    void refresh()
    $.clock.every(EVERY_MS, refresh)

    return next(e)
  })
}
