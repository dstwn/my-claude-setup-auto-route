import { atom, read, update } from 'claude-code'
import type { Register } from 'claude-code'

import type { Run } from '../types'

const PANE = 'agent-monitor'
const runs = atom({ plugin: 'agent-monitor', key: 'runs' } as const, [], {
  shape: 'runs-1',
})
const peak = atom({ plugin: 'agent-monitor', key: 'peak' } as const, 0)

// Expected family per subagent type (matches model-routing.md).
const EXPECT: Record<string, string> = {
  scout: 'haiku',
  Explore: 'haiku',
  critic: 'opus',
  'critic-lite': 'sonnet',
}

// Pure helper: '' when fine, a short warning when the model is not the family expected.
export function warn(type: string, model: string): string {
  const want = EXPECT[type]
  if (!want || !model) return ''
  return model.toLowerCase().includes(want) ? '' : `expected ${want}`
}

export function fmt(ms: number): string {
  const s = Math.max(0, Math.round(ms / 1000))
  return s < 60 ? `${s}s` : `${Math.floor(s / 60)}m${String(s % 60).padStart(2, '0')}s`
}

type Live = { id: string; status: string }

export function lines(list: Run[], live: Live[], now: number): string[] {
  const st = new Map(live.map(a => [a.id, a.status]))
  return list.map(r => {
    const s = st.get(r.id) ?? 'done'
    const w = r.note ? ` ⚠ ${r.note}` : ''
    return `${s.padEnd(9)} ${r.type.padEnd(14)} ${(r.model || '?').padEnd(18)} ${fmt(now - r.at).padStart(6)}  ${r.asked}${w}`
  })
}

export function running(list: Run[], live: Live[]): number {
  const st = new Map(live.map(a => [a.id, a.status]))
  return list.filter(r => ['pending', 'running', 'waiting'].includes(st.get(r.id) ?? '')).length
}

const NESTED = '~/.claude/nested'

// Nested sessions written by `nested-claude`: <NAME>/status + <NAME>/model. Best effort.
export async function nested($: any): Promise<string[]> {
  try {
    const dirs = (await $.fs.list(NESTED)) as { name: string; kind: string }[]
    const out: string[] = []
    for (const d of dirs.filter(x => x.kind === 'dir').slice(-8)) {
      const rd = async (f: string) => {
        try {
          return String(await $.fs.read(`${NESTED}/${d.name}/${f}`)).trim()
        } catch {
          return '?'
        }
      }
      out.push(`${(await rd('status')).padEnd(9)} ${d.name.padEnd(20)} ${await rd('model')}`)
    }
    return out
  } catch {
    return []
  }
}

async function snapshot($: any): Promise<{ list: Run[]; live: Live[]; hi: number }> {
  const list = await read($, runs)
  const hi = await read($, peak)
  let live: Live[] = []
  try {
    live = (await $.agent.list()) as Live[]
  } catch {
    live = []
  }
  return { list, live, hi }
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'monitor',
      description: 'Show subagent activity: running, peak parallel, model per run',
    })
    void $.ui.open({ id: PANE, title: 'Agents' })

    return next(e)
  })

  on('agent.spawn', async ($, e, next) => {
    const out = await next(e)
    try {
      if (out.agentId) {
        const model = out.model ?? ''
        const run: Run = {
          id: out.agentId,
          type: e.subagentType,
          model,
          asked: (e.description ?? '').slice(0, 60),
          note: warn(e.subagentType, model),
          at: await $.clock.now(),
        }
        await update($, runs, list => [...list, run].slice(-50))
        const { list, live } = await snapshot($)
        const n = running(list, live)
        await update($, peak, p => Math.max(p, n))
      }
    } catch {
      // monitoring must never break a spawn
    }

    return out
  })

  on('command.run', { command: 'monitor' }, async $ => {
    const { list, live, hi } = await snapshot($)
    const now = await $.clock.now()
    const body = lines(list.slice(-15), live, now)
    const bad = list.filter(r => r.note).length
    const head = `running ${running(list, live)} · peak parallel ${hi} · total ${list.length}` + (bad ? ` · ⚠ ${bad} model mismatch` : '')

    const nest = await nested($)

    return {
      text: [
        head,
        ...(body.length ? body : ['no subagents yet']),
        ...(nest.length ? ['', 'nested sessions:', ...nest] : []),
      ].join('\n'),
    }
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text } = $.ui.resolve(e)
    const { list, live, hi } = await snapshot($)
    const now = await $.clock.now()
    const room = Math.max(1, (e.viewport?.rows ?? 24) - 5)
    const body = lines(list.slice(-room), live, now)
    const nest = await nested($)

    return (
      <Box flexDirection="column">
        <Text bold>
          running {running(list, live)} · peak {hi} · total {list.length}
        </Text>
        {body.length === 0 && <Text dimColor>No subagents yet.</Text>}
        {body.map(l => (
          <Text dimColor={l.startsWith('done')}>{l}</Text>
        ))}
        {nest.length > 0 && <Text bold>nested sessions</Text>}
        {nest.map(l => (
          <Text dimColor={!l.startsWith('RUNNING')}>{l}</Text>
        ))}
      </Box>
    )
  })
}
