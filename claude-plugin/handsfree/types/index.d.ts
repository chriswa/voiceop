/** Hands-free as the band above the prompt draws it: Voice Operator's `/v1/voice-mode/watch`. */
export type Band = {
  /** Voice Operator's hands-free phase: `listening`, `hearing`, `sending`, or `off` (paused). */
  phase: string
  /** The conversation window is open: no trigger word needed. */
  conversation: boolean
  /** Why it is not listening just now (`speech`, `sound`, `dictation`), or null. */
  standingAside: string | null
  /** The main thread is working (the sonar). */
  working: boolean
  trigger: string
}

declare module 'claude-code' {
  interface PluginState {
    handsfree: { band: Band | null }
  }
}
