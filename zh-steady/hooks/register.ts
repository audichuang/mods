import type { PromptSubmitInput, Register } from 'claude-code'

export const REMINDER =
  '提醒：你上一段給使用者看的文字是英文。接下來所有給使用者看的文字（包括工具呼叫之間的過場說明）都用繁體中文；程式碼、指令、識別字、錯誤原文保持原樣。'

// Mostly-English test: Latin letters weighed ~4 per word against CJK chars,
// after dropping code, URLs and paths. Too short to judge -> undefined.
// URLs (any scheme) and paths match ASCII only, so CJK glued to them stays;
// both start only at a token's start, so a long token is scanned once.
export function isEnglish(text: string): boolean | undefined {
  const t = text
    .replace(/```[\s\S]*?```/g, '')
    .replace(/`[^`]*`|(?<![\w+.-])[A-Za-z][\w+.-]*:\/\/[\x21-\x7e]+|(?<![\w.~-])[\w.~-]*\/[\w.~\/-]*/g, '')
  const latin = (t.match(/[A-Za-z]/g) ?? []).length
  const cjk = (t.match(/[一-鿿]/g) ?? []).length
  if (latin + cjk < 40) return undefined
  return cjk / (latin / 4 + cjk) <= 0.3
}

// Pasted material (logs, terminal output, a page) is not the person's choice
// of language; only what they typed around it is.
// The closing tag repeats the opener's id, so a literal </pasted_content> inside stays pasted.
const PASTE = /<pasted_content( id="[^"]*")?>[\s\S]*?<\/pasted_content\1>/g

// After this many reminders in a row that the next step ignored, stop until a
// Chinese step or any new prompt: repeating it further only spends context.
export const MAX_MISSES = 3

// The person's own words: typed, through Remote Control, the SDK host, a Slack
// ping, a same-user channel the engine can't classify, or a plugin's submission
// asUser. Notifications, peers and continuations are not.
function typedByUser(e: PromptSubmitInput): boolean {
  if (e.isMeta) return false
  const o = e.origin
  return (
    o.kind === 'composer' || o.kind === 'bridge' || o.kind === 'sdk' ||
    o.kind === 'slack-ping' || o.kind === 'unclassified' ||
    (o.kind === 'plugin' && o.asUser === true)
  )
}

export const register: Register = on => {
  // Main loop only; subagent text never reaches the person directly.
  let drifted = false
  let userWantsEnglish = false
  let sent = false // a reminder went out since the last judged step
  let misses = 0

  on('prompt.submit', ($, e, next) => {
    if (typedByUser(e)) {
      const en = isEnglish(e.text.replace(PASTE, ''))
      if (en !== undefined) userWantsEnglish = en
      drifted = false
    }
    // A new prompt, typed or delivered, starts a fresh run of misses; meta
    // notices and background-task notifications landing mid-turn do not.
    if (!e.isMeta && e.origin.kind !== 'task-notification') misses = 0
    return next(e)
  })

  on('turn.step', async function* ($, e, next) {
    const r = yield* next(e)
    if (!e.agentId) {
      const en = isEnglish(r.answer)
      if (en !== undefined) {
        if (en && !userWantsEnglish) {
          if (sent) misses++
          drifted = misses < MAX_MISSES
        } else {
          drifted = false
          misses = 0
        }
        sent = false
      }
    }
    return r
  })

  on('tool.call', async ($, e, next) => {
    const r = await next(e)
    if (!drifted || e.agentId || r.deny !== undefined) return r
    drifted = false
    sent = true
    return { ...r, context: [...(r.context ?? []), REMINDER] }
  })
}
