export type Route = { tier: string; model: string; effort: string; note: string } | null

declare module 'claude-code' {
  interface PluginState {
    'auto-route': { label: string; isOn: boolean }
  }
}
