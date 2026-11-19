import { expect, test } from 'claude-code/testing'

import { classify } from './register'

test('classify picks a tier per prompt', () => {
  expect(classify('push release ke origin')).toBe('light')
  expect(classify('git status')).toBe('light')
  expect(classify('apa itu worktree?')).toBe('light')
  expect(classify('/grill-with-docs fitur export')).toBe('deep')
  expect(classify('review the security of the auth flow')).toBe('deep')
  expect(classify('implement the export feature for orders with filters and tests, touching the controller and the job')).toBe('standard')
  expect(classify('author name shown under title, please check the layout of the page and tell me what to change')).toBe('standard')
})

const usage = (tokens: number) => () => ({
  value: { startedAt: 0, context: { tokens, window: 200000 }, rateLimits: [] },
})

async function runTurn($: any, on: any, text: string, tokens: number) {
  let seen: { model: string; effort?: string } | undefined
  on('command.register', () => ({ value: { command: 'auto-route' } }))
  on('session.usage', usage(tokens))
  on('turn.start', (_: any, e: any) => ({ turnId: e.turnId }))
  on('turn.step', async function* (_: any, e: any) {
    seen = { model: e.model, effort: e.effort }
    return { turnId: e.turnId, index: e.index, answer: '', toolUses: [], stopReason: 'end_turn', usage: null }
  })
  await $.turn.start({ text, turnId: 't1' })
  const s = $.turn.step({ turnId: 't1', index: 0, model: 'claude-opus-5-5', effort: 'medium', messageCount: 1 })
  for await (const _ of s) { /* drain */ }
  return seen
}

test('light prompt in a small context is sent to sonnet/low', async ($, on) => {
  expect(await runTurn($, on, 'push release ke origin', 8000)).toEqual({ model: 'sonnet', effort: 'low' })
})

test('the same prompt in a large context keeps the session model', async ($, on) => {
  expect(await runTurn($, on, 'push release ke origin', 120000)).toEqual({ model: 'claude-opus-5-5', effort: 'medium' })
})

test('standard prompt keeps the session default', async ($, on) => {
  const p = 'implement the export feature for orders with filters and tests, touching the controller and the job'
  expect(await runTurn($, on, p, 8000)).toEqual({ model: 'claude-opus-5-5', effort: 'medium' })
})
