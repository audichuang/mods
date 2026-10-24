import { expect, test } from 'claude-code/testing'
import { REMINDER } from './register'

const EN = 'Now I will run the build and check whether the tests still pass on this branch before moving on.'
const ZH = '接下來我會先跑建置，再確認這個分支上的測試是否都還通過，然後才繼續下一步的修改工作，這樣比較保險。'

function answering(text: string) {
  return async function* (_: unknown, e: { turnId: string; index: number }) {
    return { turnId: e.turnId, index: e.index, answer: text, toolUses: [], stopReason: 'tool_use' as const, usage: null }
  }
}

async function step($: any, agentId?: string) {
  const s = $.turn.step({ turnId: 't', index: 0, model: 'm', messageCount: 1, ...(agentId ? { agentId } : {}) })
  for await (const _ of s) { /* drain */ }
}

test('English step -> next tool result carries the reminder, once', async ($, on) => {
  on('tool.call', () => ({ result: {} }))
  on('prompt.submit', (_, e) => ({ text: e.text }))
  on('turn.step', answering(EN) as any)
  await $.prompt.submit({ text: '幫我修這個 bug' } as any)
  await step($)
  const first = await $.tool.call({ tool: 'Bash', command: 'ls' })
  expect(first.context).toEqual([REMINDER])
  const second = await $.tool.call({ tool: 'Bash', command: 'ls' })
  expect(second.context).toBeUndefined()
})

test('Chinese step -> no reminder', async ($, on) => {
  on('tool.call', () => ({ result: {} }))
  on('prompt.submit', (_, e) => ({ text: e.text }))
  on('turn.step', answering(ZH) as any)
  await $.prompt.submit({ text: '幫我修這個 bug' } as any)
  await step($)
  expect((await $.tool.call({ tool: 'Bash', command: 'ls' })).context).toBeUndefined()
})

test('user wrote in English -> no reminder', async ($, on) => {
  on('tool.call', () => ({ result: {} }))
  on('prompt.submit', (_, e) => ({ text: e.text }))
  on('turn.step', answering(EN) as any)
  await $.prompt.submit({ text: 'Please fix the failing build on this branch and tell me what was wrong with it.' } as any)
  await step($)
  expect((await $.tool.call({ tool: 'Bash', command: 'ls' })).context).toBeUndefined()
})

test('subagent English step -> no reminder', async ($, on) => {
  on('tool.call', () => ({ result: {} }))
  on('prompt.submit', (_, e) => ({ text: e.text }))
  on('turn.step', answering(EN) as any)
  await $.prompt.submit({ text: '幫我修這個 bug' } as any)
  await step($, 'a1')
  expect((await $.tool.call({ tool: 'Bash', command: 'ls' })).context).toBeUndefined()
})
