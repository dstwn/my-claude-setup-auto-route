import { expect, test } from 'claude-code/testing'
import type { Note } from '../types'
import { assess, defs, parseDiff, parseNotes, symbols, validBase } from './lib'

const DIFF = `diff --git a/src/parser.py b/src/parser.py
--- a/src/parser.py
+++ b/src/parser.py
@@ -1,3 +1,3 @@
-def parse(source):
+def parse(source, lang):
     pass
diff --git a/src/model.py b/src/model.py
--- a/src/model.py
+++ b/src/model.py
@@ -1 +1,2 @@
+class Cache:
+    x = 1
diff --git a/README.md b/README.md
--- a/README.md
+++ b/README.md
@@ -1 +1 @@
-old
+new
`

test('defs and symbols read python, ts and arrows', () => {
  expect(symbols('def a(x):\nclass B:\nexport async function c(y) {}\nexport const d = (z) => 1')).toEqual(['a', 'B', 'c', 'd'])
  expect(defs('def a(x,   y):').get('a')).toBe('(x, y)')
})

test('assess: signature change is HIGH, new class MEDIUM, prose LOW', () => {
  const [p, m, r] = parseDiff(DIFF).map(assess) as [Note, Note, Note]
  expect(p.risk).toBe('HIGH')
  expect(p.note).toContain('signature changed: parse')
  expect(m.risk).toBe('MEDIUM')
  expect(m.note).toContain('new: Cache')
  expect(r.risk).toBe('LOW')
  expect(r.plus + r.minus).toBe(2)
})

test('removed definitions are HIGH', () => {
  const [d] = parseDiff('diff --git a/a.py b/a.py\n-def gone(x):\n+x = 1\n').map(assess) as [Note]
  expect(d.risk).toBe('HIGH')
  expect(d.note).toContain('removed: gone')
})

test('parseNotes accepts valid lines only and ignores unknown files', () => {
  const base = parseDiff(DIFF).map(assess)
  const out = parseNotes('src/model.py|HIGH|replaces to_json\nnope.py|LOW|x\nREADME.md|BOGUS|y\ngarbage', base)
  expect(out.find(n => n.file === 'src/model.py')?.risk).toBe('HIGH')
  expect(out.find(n => n.file === 'src/model.py')?.note).toBe('replaces to_json')
  expect(out.find(n => n.file === 'README.md')?.risk).toBe('LOW')
  expect(out.length).toBe(3)
})

test('validBase blocks option-like and shell-ish refs', () => {
  expect(validBase('')).toBe(true)
  expect(validBase('main')).toBe(true)
  expect(validBase('origin/feature/x')).toBe(true)
  expect(validBase('--output=/etc/x')).toBe(false)
  expect(validBase('a;rm -rf')).toBe(false)
})

test('/code-watch review runs git diff and answers text', async ($, on) => {
  const store: Record<string, { value: unknown; version: number }> = {}
  on('state.get', (_, e: any) => ({ value: store[e.key] ?? {} }) as any)
  on('state.set', (_, e: any) => {
    const v = (store[e.key]?.version ?? 0) + 1
    store[e.key] = { value: e.value, version: v }
    return { value: { isSet: true, version: v } } as any
  })
  on('ui.open', () => ({ value: { isPlaced: true } }))
  let argv: readonly string[] = []
  on('process.run', (_, e: any) => {
    argv = e.argv
    return { value: { exitCode: 0, stdout: DIFF, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } } as any
  })
  const r: any = await $.command.run({ command: 'code-watch', args: 'review main', origin: 'user', presentation: 'text' } as any)
  expect(JSON.stringify(r)).toContain('HIGH')
  expect(JSON.stringify(r)).toContain('src/parser.py')
  expect(argv.join(' ')).toContain('main...HEAD')
})

test('an Edit shows in the pane on every surface, a Read does not', async ($, on) => {
  const store: Record<string, { value: unknown; version: number }> = {}
  on('state.get', (_, e: any) => ({ value: store[e.key] ?? {} }) as any)
  on('state.set', (_, e: any) => {
    const v = (store[e.key]?.version ?? 0) + 1
    store[e.key] = { value: e.value, version: v }
    return { value: { isSet: true, version: v } } as any
  })
  on('clock.now', () => ({ value: 3000 }))
  on('tool.call', () => ({ result: {} }))
  await $.tool.call({ tool: 'Edit', file_path: '/r/src/a.py', old_string: 'x', new_string: 'def go(a):\n  pass' } as any)
  await $.tool.call({ tool: 'Read', file_path: '/r/src/secret.py' } as any)
  for (const surface of ['terminal', 'desktop', 'vscode', 'mobile'] as const) {
    const ui = await $.ui.mount({
      plugin: 'code-watch', component: 'Pane', requestId: 'code-watch', surface,
      props: { title: 'Code watch', isFocused: false, bodyColumns: 80, placement: 'dock', scroll: { offset: 0, bodyRows: 20 }, view: {} },
    })
    const row = await ui.find({ type: 'Text', text: /a\.py/ })
    expect(row?.text).toContain('+2 −1')
    expect(await ui.find({ type: 'Text', text: /secret/ })).toBeUndefined()
    expect((await ui.find({ type: 'Text', text: /go/ }))?.text).toContain('go')
    await ui.unmount()
  }
})
