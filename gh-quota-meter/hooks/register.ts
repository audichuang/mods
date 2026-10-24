import type { Register } from 'claude-code'

// The rate_limit endpoint itself does not count against the quota.
const EVERY_MS = 120_000
const WARN_BELOW = 1000
const JQ = '[.resources.core.remaining, .resources.core.limit, .resources.core.reset, .resources.graphql.remaining] | @tsv'
// $.process.run takes no shell, and the Claude process's PATH may lack Homebrew's bin.
const GH = ['gh', '/opt/homebrew/bin/gh', '/home/linuxbrew/.linuxbrew/bin/gh', '/usr/local/bin/gh', '/usr/bin/gh'] as const

export const register: Register = on => {
  let warnedForReset = 0
  let gh: string | undefined

  on('session.start', async ($, e, next) => {
    // The first binary that starts at all is the one; run() rejects only when it cannot start.
    const query = async () => {
      for (const bin of gh === undefined ? GH : [gh]) {
        const ran = await $.process.run([bin, 'api', 'rate_limit', '--jq', JQ], { timeoutMs: 15_000 }).catch(() => undefined)
        if (ran !== undefined) {
          gh = bin
          return ran
        }
      }
      return undefined
    }
    const refresh = async () => {
      const ran = await query()
      if (ran === undefined) {
        $.ui.status('GH 額度：找不到 gh')
        return
      }
      if (ran.exitCode !== 0) {
        $.ui.status('GH 額度：查詢失敗')
        return
      }
      // Number('') is 0, so reject empty fields before converting.
      const fields = ran.stdout.trim().split('\t')
      const [remaining, limit, reset, graphql] = fields.map(Number)
      if (fields.length !== 4 || fields.includes('') || remaining === undefined || limit === undefined || reset === undefined || graphql === undefined || [remaining, limit, reset, graphql].some(Number.isNaN)) {
        $.ui.status('GH 額度：回應格式不對')
        return
      }
      const resetAt = new Date(reset * 1000).toTimeString().slice(0, 5)
      $.ui.status(`GH ${remaining}/${limit} · GQL ${graphql} · ${resetAt} 重置`)
      if (remaining < WARN_BELOW && warnedForReset !== reset) {
        warnedForReset = reset
        $.ui.toast(`GitHub API 額度只剩 ${remaining}/${limit}，${resetAt} 重置。等 CI 用 gh-wait，別輪詢。`)
      }
    }

    // Don't hold the session start on a network call.
    void refresh()
    $.clock.every(EVERY_MS, refresh)

    return next(e)
  })
}
