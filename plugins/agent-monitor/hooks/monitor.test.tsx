import { expect, test } from 'claude-code/testing'
import { fmt, lines, running, warn } from './register'

test('warn flags a model outside the expected family', () => {
  expect(warn('scout', 'claude-haiku-5-5')).toBe('')
  expect(warn('scout', 'claude-opus-5-5')).toBe('expected haiku')
  expect(warn('critic', 'claude-sonnet-5-5')).toBe('expected opus')
  expect(warn('general-purpose', 'anything')).toBe('')
})

test('fmt and running', () => {
  expect(fmt(5000)).toBe('5s')
  expect(fmt(125000)).toBe('2m05s')
  const list = [
    { id: 'a', type: 'scout', model: 'haiku', asked: 'x', note: '', at: 0 },
    { id: 'b', type: 'critic', model: 'opus', asked: 'y', note: '', at: 0 },
  ]
  expect(running(list, [{ id: 'a', status: 'running' }, { id: 'b', status: 'completed' }])).toBe(1)
  expect(lines(list, [], 1000)[0]).toContain('done')
})

test('/monitor answers in plain text', async ($, on) => {
  on('command.register', () => ({ value: { command: 'monitor' } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('clock.now', () => ({ value: 1000 }))
  on('agent.list', () => ({ value: [] }))
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  const r = await $.command.run({ command: 'monitor' })
  expect(JSON.stringify(r)).toContain('no subagents yet')
})
