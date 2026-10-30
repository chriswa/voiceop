import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Band } from '../types'

/**
 * Hands-free voice chat with this one Claude Code session, through Voice
 * Operator (its DESIGN.md, "Claude Code voice mode"). Voice Operator listens,
 * transcribes, speaks and decides; this mod is the session's side of it:
 *
 * - `/handsfree` attaches the session (`/v1/voice-mode/attach`), which takes
 *   the Mac's hands-free from whoever had it, and lets go again.
 * - When the main thread finishes a turn, its answer goes to Voice Operator to
 *   be spoken, and the mod waits (`/next`, a long poll) for what the user says
 *   next, which it submits as the user's own prompt.
 * - While the main thread works, Voice Operator plays a sonar (`/working`);
 *   anything said meanwhile rides in with the next tool result.
 * - While attached, the system prompt carries the hands-free rules
 *   (hands-free.md), and the model has two tools: `stop` and `say`.
 * - While attached, a band above the prompt says what hands-free is doing:
 *   whether the trigger word is needed, or the user can just keep talking.
 */

type $ = EngineInterface

const VO_API_REQUIRED = 18
const RULES_ID = 'handsfree:rules'
const STOP = 'mcp__handsfree__stop'
const band = atom({ plugin: 'handsfree', key: 'band' } as const, null)
const SAY = 'mcp__handsfree__say'

/** What this session's side knows. Module state: a reload asks Voice Operator again (`resume`). */
const self = {
  attached: false,
  /** Ever attached in this process: Voice Operator may have a notice for the next prompt. */
  wasAttached: false,
  sessionId: '',
  /** The turn number Voice Operator waits for the user under. */
  generation: 0,
  /** The main thread is between turns: what the user says is submitted at once. */
  idle: true,
  polling: false,
  watching: false,
  rules: '',
  claudePid: 0,
  toolsRegistered: false,
}

// MARK: - Voice Operator

type Answer = { status: number; text: string }

async function voUrl($: $): Promise<string | undefined> {
  const home = await $.env.get('HOME')
  try {
    const discovery = JSON.parse(await $.fs.read(`${home}/Library/Application Support/VoiceOperator/speech-service.json`))
    if (typeof discovery.port !== 'number') return undefined
    if ((discovery.version ?? 0) < VO_API_REQUIRED) return undefined
    return `http://127.0.0.1:${discovery.port}`
  } catch {
    return undefined
  }
}

function form(fields: Record<string, string | number>): string {
  return Object.entries(fields).map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(String(v))}`).join('&')
}

/** One request to `/v1/voice-mode<path>`; undefined when Voice Operator is not there. */
async function vo($: $, path: string, init?: { method?: string; form?: Record<string, string | number>; json?: unknown }): Promise<Answer | undefined> {
  const url = await voUrl($)
  if (!url) return undefined
  const headers: Record<string, string> = {}
  let body: string | undefined
  if (init?.form) { body = form(init.form); headers['Content-Type'] = 'application/x-www-form-urlencoded' }
  if (init?.json !== undefined) { body = JSON.stringify(init.json); headers['Content-Type'] = 'application/json' }
  try {
    const r = await $.http.fetch(`${url}/v1/voice-mode${path}`, { method: init?.method ?? (body ? 'POST' : 'GET'), headers, body })
    return { status: r.status, text: r.text }
  } catch {
    return undefined
  }
}

function field(answer: Answer | undefined, name: string): unknown {
  try { return JSON.parse(answer?.text ?? '')[name] } catch { return undefined }
}

/** The `claude` process this session runs in: Voice Operator lets go when it is gone. */
async function claudePid($: $): Promise<number> {
  if (self.claudePid) return self.claudePid
  const r = await $.process.run(['/bin/sh', '-c', 'echo $PPID']).catch(() => undefined)
  self.claudePid = Number(r?.stdout.trim()) || 0
  return self.claudePid
}

// MARK: - Attached or not

async function attach($: $, trigger: string, voice: string): Promise<string> {
  self.sessionId = await $.session.id()
  const answer = await vo($, '/attach', {
    form: { session_id: self.sessionId, claude_pid: await claudePid($), cwd: await $.session.cwd(), trigger, voice },
  })
  if (!answer) return 'Voice Operator is not running (or is too old for hands-free). Start it from /Applications and try again.'
  if (answer.status !== 200) return `Hands-free could not start: ${String(field(answer, 'detail') ?? answer.text)}`
  const word = String(field(answer, 'trigger') ?? 'claude')
  const replaced = field(answer, 'replaced')
  await attached($, Number(field(answer, 'generation') ?? 0))
  const spoken = word.charAt(0).toUpperCase() + word.slice(1)
  await vo($, '/say', { form: { session_id: self.sessionId, text: `Hands-free is on. Say ${spoken} when you want me.` } })
  return `Hands-free is on for this session: say “${spoken}” to talk to it.`
    + (typeof replaced === 'string' ? ` (It was on in another session, ${replaced}, which no longer has it.)` : '')
}

/** Voice Operator has this session: listen, and give the model its rules and tools. */
async function attached($: $, generation: number): Promise<void> {
  self.attached = true
  self.wasAttached = true
  self.generation = generation
  if (!self.rules) self.rules = await $.fs.read(`${$.plugin.root}/hands-free.md`).catch(() => '')
  if (!self.toolsRegistered) {
    await $.tool.register({
      name: 'stop',
      description: 'Turns hands-free voice chat off for this session: the user\'s voice is no longer listened for and your replies are no longer spoken. Use when the user asks to turn hands-free, voice chat or listening off, or to go back to typing.',
      inputSchema: { type: 'object', properties: {} },
      isDeferred: false,
    })
    await $.tool.register({
      name: 'say',
      description: 'While hands-free voice chat is on: speaks one short sentence to the user now, mid-turn, without ending your turn ("On it, this takes a minute"). Plain spoken English.',
      inputSchema: { type: 'object', properties: { text: { type: 'string', description: 'What to say: one short sentence.' } }, required: ['text'] },
      isDeferred: false,
    })
    self.toolsRegistered = true
  }
  void listen($)
  void watch($)
}

function detached($: $): void {
  self.attached = false
  void update($, band, () => null)
}

async function detach($: $): Promise<string> {
  const answer = await vo($, '/detach', { form: { session_id: self.sessionId || await $.session.id() } })
  detached($)
  if (!answer) return 'Voice Operator is not running; hands-free is off.'
  if (answer.status === 409) return `Hands-free is on in another session (${String(field(answer, 'project'))}); left as it is.`
  return field(answer, 'detached') === true ? 'Hands-free is off.' : 'Hands-free was not on.'
}

/** After a reload, or Voice Operator picking the session up again: are we attached? */
async function resume($: $): Promise<void> {
  const answer = await vo($, '')
  const id = await $.session.id()
  if (field(answer, 'attached') === true && field(answer, 'session_id') === id) {
    self.sessionId = id
    await attached($, Number(field(answer, 'generation') ?? 0))
  }
}

// MARK: - Listening

/**
 * Waits for what the user says while the main thread is idle, and submits it
 * as their own prompt. One loop at a time; it ends when the session is busy
 * (its turn's end starts it again) or hands-free is off.
 */
async function listen($: $): Promise<void> {
  if (self.polling) return
  self.polling = true
  try {
    let failures = 0
    while (self.attached && self.idle) {
      const answer = await vo($, `/next?session=${encodeURIComponent(self.sessionId)}&generation=${self.generation}&wait=25`)
      if (!answer) {
        // Voice Operator restarting: it picks the attachment up again when it is back.
        if (++failures > 150) { detached($); return }
        await $.clock.sleep(2000)
        continue
      }
      failures = 0
      if (answer.status === 200) {
        self.idle = false
        await $.prompt.submit({ text: answer.text, asUser: true })
        return
      }
      if (answer.status === 410) {
        if (answer.text === 'not_attached') detached($)
        return
      }
      if (answer.status !== 204) await $.clock.sleep(2000)
    }
  } finally {
    self.polling = false
  }
}

/**
 * Keeps the band in step with Voice Operator (`/watch`, a long poll that
 * answers when the conversation's state changes), until hands-free is off.
 */
async function watch($: $): Promise<void> {
  if (self.watching) return
  self.watching = true
  try {
    let version = -1
    while (self.attached) {
      const answer = await vo($, `/watch?since=${version}&wait=25`)
      if (answer?.status !== 200) { await $.clock.sleep(2000); continue }
      const state = JSON.parse(answer.text) as Record<string, unknown>
      version = Number(state.version ?? -1)
      // Off, or moved to another session: the band goes.
      if (state.attached !== true || state.session_id !== self.sessionId) { detached($); return }
      const next: Band = {
        phase: String(state.phase ?? 'off'),
        conversation: state.conversation === true,
        standingAside: typeof state.standing_aside === 'string' ? state.standing_aside : null,
        working: state.working === true,
        trigger: String(state.trigger ?? 'claude'),
      }
      await update($, band, () => next)
    }
  } finally {
    self.watching = false
  }
}

/** What the band says: what hands-free is doing, and whether the trigger word is needed. */
function describe(b: Band): { text: string; color: string } {
  const word = b.trigger.charAt(0).toUpperCase() + b.trigger.slice(1)
  if (b.phase === 'hearing') return { text: 'Listening…', color: 'success' }
  if (b.phase === 'sending') return { text: 'Sending…', color: 'success' }
  if (b.standingAside === 'speech') return { text: 'Not listening while I speak on speakers', color: 'warning' }
  if (b.standingAside === 'dictation') return { text: 'Paused for your Fn dictation', color: 'warning' }
  if (b.phase !== 'listening') return { text: 'Microphone paused', color: 'warning' }
  return b.conversation ? { text: 'Keep talking…', color: 'success' } : { text: `Say “${word}” first`, color: 'suggestion' }
}

// MARK: - Hooks

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const started = await next(e)
    await $.command.register({
      name: 'handsfree',
      description: 'Hands-free voice chat with this session through Voice Operator (on, off, status)',
      argumentHint: '[on [trigger word] [kokoro voice] | off | status]',
    })
    await resume($)
    return started
  })

  on('command.run', { command: 'handsfree' }, async ($, e) => {
    const [verb = '', ...rest] = e.args.trim().split(/\s+/).filter(Boolean)
    const id = await $.session.id()
    const mine = self.attached && self.sessionId === id
    if (verb === 'status') {
      const answer = await vo($, '')
      if (!answer) return { text: 'Voice Operator is not running.' }
      if (field(answer, 'attached') !== true) return { text: 'Hands-free is off.' }
      if (field(answer, 'session_id') !== id) return { text: `Hands-free is on in another session (${String(field(answer, 'project'))}).` }
      return { text: `Hands-free is on: trigger word “${String(field(answer, 'trigger'))}”, ${String(field(answer, 'phase'))}, sound going to ${String(field(answer, 'route') ?? 'unknown')}.` }
    }
    if (verb === 'off' || (verb === '' && mine)) {
      const text = await detach($)
      return { text, context: [`${text} Your replies are no longer spoken; answer in text as usual.`] }
    }
    const [trigger = '', voice = ''] = verb === 'on' || verb === '' ? rest : [verb, ...rest]
    const text = await attach($, trigger, voice)
    return { text, context: self.attached ? [`${text} Follow the hands-free section of your system prompt from now on.`] : [] }
  })

  // While attached: one line above the prompt, for as long as hands-free is on.
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const b = await read($, band)
    if (!b || e.props.hasSurvey) return next(e)
    const { Box, Text } = $.ui.resolve(e)
    const { text, color } = describe(b)
    return (
      <Box>
        <Text bold>🎧 Hands-free · </Text>
        <Text color={color}>{text}</Text>
        {b.working ? <Text dimColor> · working (sonar)</Text> : null}
      </Box>
    )
  })

  // The rules, in the system prompt while attached: they outlive compaction, and go when it is off.
  on('prompt.compose', async ($, e, next) => {
    const composed = await next(e)
    if (!self.attached || !self.rules) return composed
    return { sections: [...composed.sections, { id: RULES_ID, text: self.rules, scope: 'session' as const }] }
  })

  on('turn.start', async ($, e, next) => {
    if (e.agentId === undefined && self.attached) {
      self.idle = false
      await vo($, '/working', { form: { session_id: self.sessionId, on: 1 } })
    }
    return next(e)
  })

  // The main thread's answer is spoken, and the next thing said becomes its next prompt.
  on('turn.complete', async ($, e, next) => {
    const done = await next(e)
    if (e.agentId !== undefined || !self.attached) return done
    const spoken = e.isAborted ? '' : e.answer
    const answer = await vo($, '/hooks/stop', { json: { session_id: self.sessionId, last_assistant_message: spoken } })
    if (answer?.status === 200) self.generation = Number(answer.text) || self.generation
    else if (answer?.status === 204) detached($)
    self.idle = true
    if (self.attached) void listen($)
    return done
  })

  // Words said while the main thread works go with the next tool result.
  on('tool.call', async ($, e, next) => {
    const ran = await next(e)
    if (!self.attached || e.agentId !== undefined || 'deny' in ran && ran.deny !== undefined) return ran
    const answer = await vo($, '/hooks/post-tool-use', { json: { session_id: self.sessionId } })
    const context = (field(answer, 'hookSpecificOutput') as { additionalContext?: string } | undefined)?.additionalContext
    return context ? { ...ran, context: [...(ran.context ?? []), context] } : ran
  })

  on('tool.call', { tool: STOP }, async $ => ({ result: await detach($) }))
  on('tool.call', { tool: SAY }, async ($, e) => {
    const text = typeof e.text === 'string' ? e.text : ''
    const answer = await vo($, '/say', { form: { session_id: self.sessionId, text } })
    return { result: answer?.status === 202 ? 'Said.' : 'Not said: hands-free is off.' }
  })
  // Its own tools need nobody at the keyboard.
  on('tool.check', { tool: STOP }, () => ({ decision: 'allow' as const, reason: 'hands-free\'s own control' }))
  on('tool.check', { tool: SAY }, () => ({ decision: 'allow' as const, reason: 'hands-free\'s own control' }))

  // Typed at the keyboard: if hands-free went off under the session (Spaceterm took it back,
  // "let me turn this off"), or the user spoke meanwhile, that goes with the prompt.
  on('prompt.submit', async ($, e, next) => {
    if (!self.wasAttached || e.origin.kind !== 'composer') return next(e)
    const answer = await vo($, '/hooks/user-prompt-submit', { json: { session_id: await $.session.id() } })
    if (answer?.status !== 200 || !answer.text) return next(e)
    const check = await vo($, '')
    if (field(check, 'session_id') !== self.sessionId) detached($)
    return next({ ...e, context: [...(e.context ?? []), answer.text] })
  })

  // A permission prompt nobody can see: said aloud.
  on('classic.Notification', async ($, e, next) => {
    if (self.attached && e.notification_type !== 'idle_prompt') {
      await vo($, '/hooks/notification', { json: { session_id: self.sessionId, message: e.message, notification_type: e.notification_type } })
    }
    return next(e)
  })

  on('session.end', async ($, e, next) => {
    if (self.attached && e.reason === 'clear') {
      // /clear goes on under a new session id in this process: hands-free follows it.
      $.clock.after(500, async () => {
        const id = await $.session.id()
        self.sessionId = id
        await vo($, `/hooks/session-start?claude_pid=${await claudePid($)}`, { json: { session_id: id, source: 'clear' } })
      })
    } else if (self.attached) {
      await vo($, '/hooks/session-end', { json: { session_id: self.sessionId, reason: e.reason } })
      detached($)
    }
    return next(e)
  })
}
