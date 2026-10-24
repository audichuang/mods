import type { Register } from 'claude-code'

export const REMINDER =
  '提醒：你上一段給使用者看的文字是英文。接下來所有給使用者看的文字（包括工具呼叫之間的過場說明）都用繁體中文；程式碼、指令、識別字、錯誤原文保持原樣。'

// Mostly-English test: Latin letters weighed ~4 per word against CJK chars,
// after dropping code, URLs and paths. Too short to judge -> undefined.
export function isEnglish(text: string): boolean | undefined {
  const t = text
    .replace(/```[\s\S]*?```/g, '')
    .replace(/`[^`]*`|https?:\/\/\S+|\S*\/\S+/g, '')
  const latin = (t.match(/[A-Za-z]/g) ?? []).length
  const cjk = (t.match(/[一-鿿]/g) ?? []).length
  if (latin + cjk < 40) return undefined
  return cjk / (latin / 4 + cjk) <= 0.3
}

export const register: Register = on => {
  // Main loop only; subagent text never reaches the person directly.
  let drifted = false
  let userWantsEnglish = false

  on('prompt.submit', ($, e, next) => {
    userWantsEnglish = isEnglish(e.text) === true
    drifted = false
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
