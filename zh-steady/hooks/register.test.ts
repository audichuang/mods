import { expect, test } from 'claude-code/testing'
import { REMINDER, isEnglish } from './register'

const EN = 'Now I will run the build and check whether the tests still pass on this branch before moving on.'
const ZH = '接下來我會先跑建置，再確認這個分支上的測試是否都還通過，然後才繼續下一步的修改工作，這樣比較保險。'
const EN_PROMPT = 'Please fix the failing build on this branch and tell me what was wrong with it.'
const NOTICE = '<task-notification>I reviewed the plugin and found two real defects in the prompt hook and its tests.</task-notification>'

// What the person typed at the prompt, as the engine stamps it.
const typed = (text: string) => ({ text, wait: false, origin: { kind: 'composer' as const } })

function answering(...texts: string[]) {
  let i = 0
  return async function* (_: unknown, e: { turnId: string; index: number }) {
    const answer = texts[Math.min(i++, texts.length - 1)]!
    return { turnId: e.turnId, index: e.index, answer, toolUses: [], stopReason: 'tool_use' as const, usage: null }
  }
}

async function step($: any, agentId?: string) {
  const s = $.turn.step({ turnId: 't', index: 0, model: 'm', messageCount: 1, ...(agentId ? { agentId } : {}) })
  for await (const _ of s) { /* drain */ }
}

function setup(on: any, ...answers: string[]) {
  on('tool.call', () => ({ result: {} }))
  on('prompt.submit', (_: unknown, e: { text: string }) => ({ text: e.text }))
  on('turn.step', answering(...answers) as any)
}

const bash = ($: any, extra = {}) => $.tool.call({ tool: 'Bash', command: 'ls', ...extra })

test('English step -> next tool result carries the reminder, once', async ($, on) => {
  setup(on, EN)
  await $.prompt.submit(typed('幫我修這個 bug'))
  await step($)
  expect((await bash($)).context).toEqual([REMINDER])
  expect((await bash($)).context).toBeUndefined()
})

test('Chinese step -> no reminder', async ($, on) => {
  setup(on, ZH)
  await $.prompt.submit(typed('幫我修這個 bug'))
  await step($)
  expect((await bash($)).context).toBeUndefined()
})

test('user wrote in English -> no reminder', async ($, on) => {
  setup(on, EN)
  await $.prompt.submit(typed(EN_PROMPT))
  await step($)
  expect((await bash($)).context).toBeUndefined()
})

test('subagent English step -> no reminder', async ($, on) => {
  setup(on, EN)
  await $.prompt.submit(typed('幫我修這個 bug'))
  await step($, 'a1')
  expect((await bash($)).context).toBeUndefined()
})

// #11/#13: only the person's own words set the language preference.

test('English task notification does not turn the nudge off', async ($, on) => {
  setup(on, EN)
  await $.prompt.submit(typed('幫我修這個 bug'))
  await $.prompt.submit({ text: NOTICE, wait: false, isMeta: true, origin: { kind: 'task-notification' } })
  await step($)
  expect((await bash($)).context).toEqual([REMINDER])
})

test('machine-delivered English prompts never count as the user choosing English', async ($, on) => {
  setup(on, EN)
  await $.prompt.submit(typed('幫我修這個 bug'))
  const origins = [
    { kind: 'peer' }, { kind: 'peer-send-message' }, { kind: 'scheduled-trigger' }, { kind: 'auto-continuation' },
    { kind: 'unclassified' }, { kind: 'coordinator' }, { kind: 'channel', server: 's' }, { kind: 'plugin', name: 'p' },
  ] as const
  for (const origin of origins) {
    await $.prompt.submit({ text: EN_PROMPT, wait: false, origin })
    await step($)
    expect((await bash($)).context).toEqual([REMINDER])
  }
})

test('an English isMeta prompt is not the user typing, whatever its origin', async ($, on) => {
  setup(on, EN)
  await $.prompt.submit(typed('幫我修這個 bug'))
  await $.prompt.submit({ text: EN_PROMPT, wait: false, isMeta: true, origin: { kind: 'composer' } })
  await step($)
  expect((await bash($)).context).toEqual([REMINDER])
})

test('a notification between the English step and the tool call keeps the pending reminder', async ($, on) => {
  setup(on, EN)
  await $.prompt.submit(typed('幫我修這個 bug'))
  await step($)
  await $.prompt.submit({ text: NOTICE, wait: false, isMeta: true, origin: { kind: 'task-notification' }, turnId: 't' })
  expect((await bash($)).context).toEqual([REMINDER])
})

test('the person\'s English through bridge, sdk or a plugin asUser counts', async ($, on) => {
  setup(on, EN)
  const origins = [{ kind: 'bridge' }, { kind: 'sdk' }, { kind: 'plugin', name: 'p', asUser: true }] as const
  for (const origin of origins) {
    await $.prompt.submit(typed('幫我修這個 bug'))
    await $.prompt.submit({ text: EN_PROMPT, wait: false, origin })
    await step($)
    expect((await bash($)).context).toBeUndefined()
  }
})

// #55: a prompt too short to judge keeps the last known preference.

test('long English prompt, then a short one -> still English, no reminder', async ($, on) => {
  setup(on, EN)
  await $.prompt.submit(typed(EN_PROMPT))
  await $.prompt.submit(typed('yes, go ahead'))
  await step($)
  expect((await bash($)).context).toBeUndefined()
})

test('Chinese prompt, then a short one -> still Chinese, reminder', async ($, on) => {
  setup(on, EN)
  await $.prompt.submit(typed('幫我修這個 bug，順便看看測試為什麼一直失敗，然後告訴我原因和你打算怎麼修改這個部分比較好'))
  await $.prompt.submit(typed('ok'))
  await step($)
  expect((await bash($)).context).toEqual([REMINDER])
})

test('English preference switches back once the user writes Chinese at length', async ($, on) => {
  setup(on, EN)
  await $.prompt.submit(typed(EN_PROMPT))
  await $.prompt.submit(typed('幫我修這個 bug，順便看看測試為什麼一直失敗，然後告訴我原因和你打算怎麼修改這個部分比較好'))
  await step($)
  expect((await bash($)).context).toEqual([REMINDER])
})

// #15: the state machine's other branches.

test('English step then Chinese step -> drift cleared, no reminder', async ($, on) => {
  setup(on, EN, ZH)
  await $.prompt.submit(typed('幫我修這個 bug'))
  await step($)
  await step($)
  expect((await bash($)).context).toBeUndefined()
})

test('English step then a too-short step -> drift carries over', async ($, on) => {
  setup(on, EN, 'ok')
  await $.prompt.submit(typed('幫我修這個 bug'))
  await step($)
  await step($)
  expect((await bash($)).context).toEqual([REMINDER])
})

test('denied tool call does not use up the reminder', async ($, on) => {
  let calls = 0
  on('tool.call', () => (calls++ === 0 ? { deny: 'no' } : { result: {} }))
  on('prompt.submit', (_, e) => ({ text: e.text }))
  on('turn.step', answering(EN) as any)
  await $.prompt.submit(typed('幫我修這個 bug'))
  await step($)
  const denied = await bash($)
  expect(denied.context).toBeUndefined()
  expect((await bash($)).context).toEqual([REMINDER])
})

test('reminder is appended to context other hooks returned', async ($, on) => {
  on('tool.call', () => ({ result: {}, context: ['x'] }))
  on('prompt.submit', (_, e) => ({ text: e.text }))
  on('turn.step', answering(EN) as any)
  await $.prompt.submit(typed('幫我修這個 bug'))
  await step($)
  expect((await bash($)).context).toEqual(['x', REMINDER])
})

test('subagent tool call while drifted gets nothing and leaves the reminder for the main loop', async ($, on) => {
  setup(on, EN)
  await $.prompt.submit(typed('幫我修這個 bug'))
  await step($)
  expect((await bash($, { agentId: 'a1' })).context).toBeUndefined()
  expect((await bash($)).context).toEqual([REMINDER])
})

test('a new prompt from the user clears a pending reminder', async ($, on) => {
  setup(on, EN)
  await $.prompt.submit(typed('幫我修這個 bug'))
  await step($)
  await $.prompt.submit(typed('好'))
  expect((await bash($)).context).toBeUndefined()
})

// #56: isEnglish's rules, directly.

test('isEnglish: 40-letter floor', () => {
  expect(isEnglish('')).toBeUndefined()
  expect(isEnglish('a'.repeat(39))).toBeUndefined()
  expect(isEnglish('a'.repeat(40))).toBe(true)
  expect(isEnglish('中'.repeat(39))).toBeUndefined()
  expect(isEnglish('中'.repeat(40))).toBe(false)
  expect(isEnglish('yes, go ahead')).toBeUndefined()
})

test('isEnglish: 0.3 ratio with letters weighed 4 per CJK char', () => {
  const latin = 'word '.repeat(100) // 400 letters, weighs as 100
  expect(isEnglish(latin + '中'.repeat(42))).toBe(true) // 42/142 = 0.296
  expect(isEnglish(latin + '中'.repeat(43))).toBe(false) // 43/143 = 0.301
})

test('isEnglish: code, URLs and paths do not count', () => {
  expect(isEnglish('```\n' + EN + '\n' + EN + '\n```\n好了')).toBeUndefined()
  expect(isEnglish('```\n' + EN + '\n```\n' + ZH)).toBe(false)
  expect(isEnglish('我把 `someVeryLongIdentifierNameThatIsDefinitelyMoreThanFortyLetters` 改掉了')).toBeUndefined()
  expect(isEnglish('我把 `someVeryLongIdentifierNameThatIsDefinitelyMoreThanFortyLetters` 改掉了，' + ZH)).toBe(false)
  expect(isEnglish('see https://example.com/some/very/long/path/with/many/english/words/in/it ok')).toBeUndefined()
  expect(isEnglish('/usr/local/share/some/really/long/english/looking/directory/name/here')).toBeUndefined()
})

// #14: stripping a path or URL leaves the CJK text around it.

test('isEnglish: a path glued to Chinese does not eat the Chinese', () => {
  const t = '我已經把hooks/register.ts裡面的判斷邏輯改成先去掉程式碼區塊再計算中文字比例，這樣比較準確也不會誤判，接下來會再跑一次完整測試確認沒有問題 (see the PR description for the details and the full test plan)'
  expect(isEnglish(t)).toBe(false)
  expect(isEnglish('看 https://example.com/aaaa 和 src/bbbb，' + ZH)).toBe(false)
  expect(isEnglish('看https://example.com/aaaa和src/bbbb，' + ZH)).toBe(false)
  expect(isEnglish('改了src/a.ts、lib/b.ts，' + ZH)).toBe(false)
})

test('Chinese answer with a glued path -> no reminder', async ($, on) => {
  setup(on, '我已經把hooks/register.ts裡面的判斷邏輯改成先去掉程式碼區塊再計算中文字比例，這樣比較準確也不會誤判，接下來會再跑一次完整測試確認沒有問題 (see the PR description for the details and the full test plan)')
  await $.prompt.submit(typed('幫我修這個 bug'))
  await step($)
  expect((await bash($)).context).toBeUndefined()
})

// #12: linear time on long text with no whitespace.

test('isEnglish: 200 KB without spaces finishes fast', () => {
  const blobs = [
    'a'.repeat(200_000),
    '{"key":"value","n":12345},'.repeat(8_000),
    '```' + 'b'.repeat(200_000),
    'x.y-z~'.repeat(35_000),
    '中a'.repeat(100_000),
  ]
  for (const blob of blobs) {
    const t0 = Date.now()
    isEnglish(blob)
    expect(Date.now() - t0).toBeLessThan(500)
  }
})
