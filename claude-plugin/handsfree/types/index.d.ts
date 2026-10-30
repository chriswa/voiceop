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
  /** Speech that needed the trigger word just came without it (a few seconds' alarm). */
  missedTrigger: boolean
  /** What was heard instead of the trigger word, the last time: shown with the alarm. */
  missedHeard: string | null
  /** Hands-free has committed to a dictation: the user's words are being taken down. */
  transcribing: boolean
  /** Voice Operator is speaking. */
  speaking: boolean
  /** Where the sound goes: `ear` (headset), `open` (speakers the mic hears), `unsure`, or null. */
  route: string | null
  /** The speakers echo experiment is listening through our voice here. */
  echoActive: boolean
  trigger: string
}

declare module 'claude-code' {
  interface PluginState {
    handsfree: { band: Band | null }
  }
}
