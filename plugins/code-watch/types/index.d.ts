export type Touch = { file: string; tool: string; plus: number; minus: number; symbols: string[]; at: number }
export type Note = { file: string; risk: string; plus: number; minus: number; note: string }

declare module 'claude-code' {
  interface PluginState {
    'code-watch': { touches: Shaped<Touch[]>; notes: Shaped<Note[]>; base: string }
  }
}
