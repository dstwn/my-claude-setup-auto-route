import { atom, read, update } from 'claude-code'
import type { Register } from 'claude-code'

import type { Note, Touch } from '../types'
import { assess, countLines, fmtAge, parseDiff, parseNotes, riskTone, symbols, validBase } from './lib'

const PANE = 'code-watch'
const touches = atom({ plugin: 'code-watch', key: 'touches' } as const, [], { shape: 'touches-1' })
const notes = atom({ plugin: 'code-watch', key: 'notes' } as const, [], { shape: 'notes-1' })
const base = atom({ plugin: 'code-watch', key: 'base' } as const, '')

const WRITERS = ['Edit', 'Write', 'MultiEdit', 'NotebookEdit']

function touchOf(e: any, at: number): Touch | undefined {
  const file = String(e.file_path ?? e.notebook_path ?? '')
  if (!file) return undefined
  const oldS = String(e.old_string ?? '')
  const newS = String(e.new_string ?? e.content ?? e.new_source ?? '')
  return {
    file,
    tool: String(e.tool),
    plus: countLines(newS),
    minus: countLines(oldS),
    symbols: symbols(newS || oldS),
    at,
  }
}

async function review($: any, arg: string, ai: boolean): Promise<string> {
  const argv = arg ? ['git', 'diff', `${arg}...HEAD`] : ['git', 'diff', 'HEAD']
  const run = await $.process.run(argv)
  if (run.exitCode !== 0) return `git diff failed: ${String(run.stderr).slice(0, 200)}`
  const files = parseDiff(String(run.stdout))
  if (files.length === 0) return 'nothing to review: no changes'
  let result: Note[] = files.map(assess)
  let how = 'heuristic'
  if (ai) {
    try {
      const diff = String(run.stdout).slice(0, 12000)
      const out = await $.model.complete({
        model: 'sonnet',
        prompt:
          'Review this diff. For EVERY changed file output exactly one line: path|RISK|note, RISK is LOW, MEDIUM or HIGH, ' +
          'note is one sentence naming the symbols that changed and whether callers break. No other text.\n\n' +
          diff,
      })
      if (out.isAnswered) {
        result = parseNotes(String(out.text), result)
        how = 'AI + heuristic'
      }
    } catch {
      // keep heuristic notes
    }
  }
  await update($, notes, () => result)
  await update($, base, () => arg || 'HEAD')
  return `${how} review of ${files.length} file(s):\n` + result.map(n => `${n.risk.padEnd(6)} ${n.file} +${n.plus} -${n.minus} — ${n.note}`).join('\n')
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'code-watch',
      description: 'Open the pane of files the agent touches; /code-watch review [base] [--ai] for risk notes',
    })
    void $.ui.open({ id: PANE, title: 'Code watch' })

    return next(e)
  })

  on('tool.call', async ($, e, next) => {
    const ran = await next(e)
    try {
      if (WRITERS.includes(String((e as any).tool))) {
        const t = touchOf(e, await $.clock.now())
        if (t) await update($, touches, list => [...list, t].slice(-30))
      }
    } catch {
      // watching must never break a tool call
    }

    return ran
  })

  on('command.run', { command: 'code-watch' }, async ($, e) => {
    const words = String((e as any).args ?? '').trim().split(/\s+/).filter(Boolean)
    if (words[0] !== 'review') {
      await $.ui.open({ id: PANE, title: 'Code watch' })

      return { text: 'Code watch pane opened. Use: /code-watch review [base-branch] [--ai]' }
    }
    const ai = words.includes('--ai')
    const arg = words.slice(1).filter(w => w !== '--ai').join(' ')
    if (!validBase(arg)) return { text: 'invalid base ref' }
    await $.ui.open({ id: PANE, title: 'Code watch' })

    return { text: await review($, arg, ai) }
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text } = $.ui.resolve(e)
    const list = await read($, touches)
    const ns = await read($, notes)
    const from = await read($, base)
    const now = await $.clock.now()
    const room = Math.max(3, Math.floor(((e.viewport?.rows ?? 24) - 6) / 2))
    const rows = list.slice(-room).reverse()

    return (
      <Box flexDirection="column" gap={1}>
        <Text bold>{`LIVE · ${list.length} change(s) this session`}</Text>
        {rows.length === 0 && <Text dimColor>No edits yet. Files the agent changes show up here.</Text>}
        <Box flexDirection="column">
          {rows.map((t, i) => {
            const fresh = now - t.at < 10000
            return (
              <Box flexDirection="column">
                <Text bold={fresh} color={fresh ? 'cyan' : undefined} dimColor={!fresh && i > 0}>
                  {`${fresh ? '◉' : '○'} ${t.file}  +${t.plus} −${t.minus}  ${fmtAge(now - t.at)} ago`}
                </Text>
                {t.symbols.length > 0 && <Text dimColor>{`    ${t.symbols.join('  ·  ')}`}</Text>}
              </Box>
            )
          })}
        </Box>
        {ns.length > 0 && (
          <Box flexDirection="column">
            <Text bold>{`REVIEW NOTES · ${from}`}</Text>
            {ns.map(n => (
              <Box flexDirection="column">
                <Text color={riskTone(n.risk)} bold>{`${n.risk.padEnd(6)} ${n.file}  +${n.plus} −${n.minus}`}</Text>
                <Text dimColor>{`       ${n.note}`}</Text>
              </Box>
            ))}
          </Box>
        )}
      </Box>
    )
  })
}
