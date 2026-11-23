export type Run = {
  id: string
  type: string
  model: string
  asked: string
  note: string
  at: number
}

declare module 'claude-code' {
  interface PluginState {
    'agent-monitor': { runs: Shaped<Run[]>; peak: number }
  }
}
