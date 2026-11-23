import { expect, test } from 'claude-code/testing'
import { fmt, lines, nested, running, warn } from './register'

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

test('nested reads status and model per session, and survives a missing dir', async () => {
  const files: Record<string, string> = {
    '~/.claude/nested/PROJ-1/status': 'RUNNING\n',
    '~/.claude/nested/PROJ-1/model': 'sonnet/light',
  }
  const ok = {
    fs: {
      list: async () => [{ name: 'PROJ-1', kind: 'dir' }, { name: 'x.txt', kind: 'file' }],
      read: async (p: string) => {
        if (!(p in files)) throw new Error('nope')
        return files[p]
      },
    },
  }
  const got = await nested(ok)
  expect(got.length).toBe(1)
  expect(got[0]).toContain('RUNNING')
  expect(got[0]).toContain('PROJ-1')
  expect(got[0]).toContain('sonnet/light')
  expect(await nested({ fs: { list: async () => { throw new Error('x') } } })).toEqual([])
})
