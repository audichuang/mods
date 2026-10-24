import type { PromptSubmitInput, Register } from 'claude-code'

export const REMINDER =
  '提醒：你上一段給使用者看的文字是英文。接下來所有給使用者看的文字（包括工具呼叫之間的過場說明）都用繁體中文；程式碼、指令、識別字、錯誤原文保持原樣。'

// Mostly-English test: Latin letters weighed ~4 per word against CJK chars,
// after dropping code, URLs and paths. Too short to judge -> undefined.
// URLs and paths match ASCII only, so CJK glued to them stays; a path starts
// only at a token's start, so a long token without '/' is scanned once.
export function isEnglish(text: string): boolean | undefined {
  const t = text
    .replace(/```[\s\S]*?```/g, '')
    .replace(/`[^`]*`|https?:\/\/[\x21-\x7e]+|(?<![\w.~-])[\w.~-]*\/[\w.~\/-]*/g, '')
  const latin = (t.match(/[A-Za-z]/g) ?? []).length
  const cjk = (t.match(/[一-鿿]/g) ?? []).length
  if (latin + cjk < 40) return undefined
  return cjk / (latin / 4 + cjk) <= 0.3
}

// The person's own words: typed, through Remote Control or the SDK host, or
// a plugin's submission asUser. Notifications, peers and continuations are not.
function typedByUser(e: PromptSubmitInput): boolean {
  if (e.isMeta) return false
  const o = e.origin
  return o.kind === 'composer' || o.kind === 'bridge' || o.kind === 'sdk' || (o.kind === 'plugin' && o.asUser === true)
}

export const register: Register = on => {
  // Main loop only; subagent text never reaches the person directly.
  let drifted = false
  let userWantsEnglish = false

  on('prompt.submit', ($, e, next) => {
    if (typedByUser(e)) {
      const en = isEnglish(e.text)
      if (en !== undefined) userWantsEnglish = en
      drifted = false
    }
    return next(e)
  })

  on('turn.step', async function* ($, e, next) {
    const r = yield* next(e)
    if (!e.agentId) {
      const en = isEnglish(r.answer)
      if (en !== undefined) drifted = en && !userWantsEnglish
    }
    return r
  })

  on('tool.call', async ($, e, next) => {
    const r = await next(e)
    if (!drifted || e.agentId || r.deny !== undefined) return r
    drifted = false
    return { ...r, context: [...(r.context ?? []), REMINDER] }
  })
}
