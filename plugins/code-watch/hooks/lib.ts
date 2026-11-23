import type { Note } from '../types'

const DEF =
  /^\s*(?:export\s+)?(?:default\s+)?(?:async\s+)?(?:def|function\*?|class|func|fn|interface|type)\s+([A-Za-z_$][\w$]*)\s*(\([^)]*\))?/
const ARROW = /^\s*(?:export\s+)?const\s+([A-Za-z_$][\w$]*)\s*=\s*(?:async\s*)?(\([^)]*\))\s*(?:=>|:)/

// name -> signature ('' when the construct has none, like a class)
export function defs(text: string): Map<string, string> {
  const out = new Map<string, string>()
  for (const line of text.split('\n')) {
    const m = DEF.exec(line) ?? ARROW.exec(line)
    if (m && m[1]) out.set(m[1], (m[2] ?? '').replace(/\s+/g, ' '))
  }
  return out
}

export function symbols(text: string): string[] {
  return [...defs(text).keys()].slice(0, 6)
}

export function countLines(text: string): number {
  return text === '' ? 0 : text.split('\n').length
}

export type FileDiff = { file: string; plus: number; minus: number; added: string; removed: string }

export function parseDiff(diff: string): FileDiff[] {
  const out: FileDiff[] = []
  let cur: FileDiff | undefined
  for (const line of diff.split('\n')) {
    if (line.startsWith('diff --git ')) {
      const m = /^diff --git a\/(.+) b\/(.+)$/.exec(line)
      cur = { file: m?.[2] ?? line.slice(11), plus: 0, minus: 0, added: '', removed: '' }
      out.push(cur)
    } else if (cur && line.startsWith('+') && !line.startsWith('+++')) {
      cur.plus++
      cur.added += line.slice(1) + '\n'
    } else if (cur && line.startsWith('-') && !line.startsWith('---')) {
      cur.minus++
      cur.removed += line.slice(1) + '\n'
    }
  }
  return out
}

// Heuristic review of one file's diff: risk plus a one-line synopsis.
export function assess(d: FileDiff): Note {
  const a = defs(d.added)
  const r = defs(d.removed)
  const changed = [...a].filter(([n, s]) => r.has(n) && r.get(n) !== s).map(([n]) => n)
  const added = [...a.keys()].filter(n => !r.has(n))
  const removed = [...r.keys()].filter(n => !a.has(n))
  const parts: string[] = []
  if (changed.length) parts.push(`signature changed: ${changed.join(', ')}`)
  if (added.length) parts.push(`new: ${added.join(', ')}`)
  if (removed.length) parts.push(`removed: ${removed.join(', ')}`)
  const size = d.plus + d.minus
  let risk = 'LOW'
  if (changed.length || removed.length || size > 150) risk = 'HIGH'
  else if (added.length || size > 30) risk = 'MEDIUM'
  if (!parts.length) parts.push(`${size} changed lines, no definition changes`)
  return { file: d.file, risk, plus: d.plus, minus: d.minus, note: parts.join('; ') }
}

// "path|RISK|note" lines from the model; only files in `known`, only valid risks.
export function parseNotes(text: string, known: Note[]): Note[] {
  const by = new Map(known.map(n => [n.file, n]))
  const out = new Map(by)
  for (const line of text.split('\n')) {
    const [file, risk, ...rest] = line.split('|').map(s => s.trim())
    const base = by.get(file ?? '')
    const r = (risk ?? '').toUpperCase()
    if (file && base && ['LOW', 'MEDIUM', 'HIGH'].includes(r) && rest.join('|').trim()) {
      out.set(file, { ...base, risk: r, note: rest.join('|').trim().slice(0, 240) })
    }
  }
  return [...out.values()]
}

export function validBase(arg: string): boolean {
  return arg === '' || /^[\w][\w./~^@-]*$/.test(arg)
}

export function fmtAge(ms: number): string {
  const s = Math.max(0, Math.round(ms / 1000))
  return s < 60 ? `${s}s` : `${Math.floor(s / 60)}m`
}

export function riskTone(risk: string): string {
  return risk === 'HIGH' ? 'red' : risk === 'MEDIUM' ? 'yellow' : 'green'
}
