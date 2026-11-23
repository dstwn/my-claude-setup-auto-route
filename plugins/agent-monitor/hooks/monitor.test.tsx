import { expect, test } from 'claude-code/testing'
import { fmt, icon, lines, nested, running, tone, warn } from './register'

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
  const r = await $.command.run({ command: 'monitor' } as any)
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

test('icon and tone', () => {
  expect(icon('running')).toBe('●')
  expect(icon('failed')).toBe('✗')
  expect(icon('done')).toBe('✓')
  expect(tone('running', false)).toBe('green')
  expect(tone('running', true)).toBe('yellow')
  expect(tone('failed', false)).toBe('red')
  expect(tone('done', false)).toBe('gray')
})

test('pane renders header and rows on every surface', async ($, on) => {
  // The engine's state: an in-memory map, so what update() writes is what read() sees.
  const store: Record<string, { value: unknown; version: number }> = {}
  on('state.get', (_, e: any) => ({ value: store[e.key] ?? {} }) as any)
  on('state.set', (_, e: any) => {
    const v = (store[e.key]?.version ?? 0) + 1
    store[e.key] = { value: e.value, version: v }
    return { value: { version: v } } as any
  })
  on('clock.now', () => ({ value: 5000 }))
  on('agent.list', () => ({ value: [{ id: 'a', status: 'running' }] as any }))
  on('fs.list', () => ({ value: [] }))
  on('agent.spawn', () => ({ model: 'claude-opus-5-5', agentId: 'a' }))
  await $.agent.spawn({ subagentType: 'scout', description: 'find x', prompt: 'p' } as any)
  for (const surface of ['terminal', 'desktop', 'vscode', 'mobile'] as const) {
    const ui = await $.ui.mount({
      plugin: 'agent-monitor', component: 'Pane', requestId: 'agent-monitor', surface,
      props: { title: 'Agents', isFocused: false, bodyColumns: 80, placement: 'dock', scroll: { offset: 0, bodyRows: 20 }, view: {} },
    })
    const row = await ui.find({ type: 'Text', text: /scout/ })
    expect(row?.text).toContain('expected haiku')
    expect(row?.text).toContain('●')
    await ui.unmount()
  }
})
