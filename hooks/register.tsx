import { atom, read, update } from 'claude-code'
import type { Register } from 'claude-code'

// ── Tabel routing (ubah di sini) ───────────────────────────────────
// null = biarkan model/effort sesi apa adanya (aman untuk "standard").
const ROUTES = {
  light: { model: 'sonnet', effort: 'low' },
  standard: null,
  deep: { model: 'opus', effort: 'high' },
} as const
type Tier = keyof typeof ROUTES
const KEEP_ABOVE_TOKENS = 40000 // konteks lebih besar -> jangan ganti model (cache hangat hilang), naik maupun turun

const label = atom({ plugin: 'auto-route', key: 'label' } as const, '')
const isOn = atom({ plugin: 'auto-route', key: 'isOn' } as const, true)

const DEEP =
  /\b(security|auth(n|z|entication|orization)?|permission|migration|migrasi|architecture|arsitektur|refactor|race condition|root cause|intermittent|incident|payment|data integrity|rancang|design|spec|plan)\b|^\/(grill-with-docs|to-spec|to-tickets|code-review|implement-spec|nested-implement)\b/i
const LIGHT =
  /^(\/?(git|push|pull|commit|status|diff|log|ls|cat)\b|(cek|lihat|baca|tampilkan|show|list|rename|format|lint|apa itu|what is|jelaskan singkat|run tests?)\b)/i

export function classify(text: string): Tier {
  const t = text.trim()
  if (DEEP.test(t)) return 'deep'
  if (t.length <= 120 && LIGHT.test(t)) return 'light'
  if (t.length <= 60 && !t.includes('\n') && !/\b(implement|buat|tambah|fix|perbaiki|bikin|add|build|write)\b/i.test(t)) return 'light'
  return 'standard'
}

const alias = (m: string) => (/opus/i.test(m) ? 'opus' : /sonnet/i.test(m) ? 'sonnet' : /haiku/i.test(m) ? 'haiku' : m)

// label: band di atas prompt + entri status line (dua jalur, karena tidak semua surface menggambar band)
async function show($: any, text: string) {
  await update($, label, () => text)
  $.ui.status(text || undefined)
}

export const register: Register = on => {
  const routeByTurn = new Map<string, { model: string; effort: string }>()

  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'auto-route',
      description: 'Routing model/effort otomatis per prompt: on | off | status',
      argumentHint: '[on|off|status]',
    })
    return next(e)
  })

  on('command.run', { command: 'auto-route' }, async ($, e) => {
    const arg = e.args.trim().toLowerCase()
    if (arg === 'on' || arg === 'off') {
      await update($, isOn, () => arg === 'on')
      if (arg === 'off') await show($, '')
      return { text: `auto-route ${arg}.` }
    }
    const on_ = await read($, isOn)
    return { text: `auto-route ${on_ ? 'on' : 'off'} · ambang keep: ${KEEP_ABOVE_TOKENS} token · terakhir: ${(await read($, label)) || '-'}` }
  })

  on('turn.start', async ($, e, next) => {
    try {
      if (e.agentId === undefined && e.text) {
        routeByTurn.delete(e.turnId)
        if (await read($, isOn)) {
          const tier = classify(e.text)
          const target = ROUTES[tier]
          const tokens = (await $.session.usage()).context.tokens ?? 0
          if (target === null) {
            await show($, `auto · ${tier} → session default`)
          } else if (tokens > KEEP_ABOVE_TOKENS) {
            await show($, `auto · ${tier} → keep (ctx ${Math.round(tokens / 1000)}k)`)
          } else {
            routeByTurn.set(e.turnId, target)
            await show($, `auto · ${tier} → ${target.model} · ${target.effort}`)
          }
        }
      }
    } catch {
      // gagal diam-diam: tanpa routing
    }
    return next(e)
  })

  on('turn.step', async function* ($, e, next) {
    const r = e.agentId === undefined ? routeByTurn.get(e.turnId) : undefined
    if (!r) return yield* next(e)
    const sameModel = alias(e.model) === r.model
    return yield* next({
      ...e,
      model: sameModel ? e.model : r.model,
      effort: r.effort as 'low' | 'medium' | 'high' | 'xhigh' | 'max',
    })
  })

  on('turn.complete', async ($, e, next) => {
    routeByTurn.delete(e.turnId)
    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const text = await read($, label)
    if (!text || e.props.hasSurvey) return next(e)
    const { Box, Text } = $.ui.resolve(e)
    return (
      <Box>
        <Text dimColor>{text}</Text>
      </Box>
    )
  })
}
