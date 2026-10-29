# Single-Agent Voice Mode

A Claude Code plugin for talking with **one** Claude Code session hands-free,
through [Voice Operator](../../README.md). You type one command in the session,
then put the keyboard down: the agent's replies are spoken by Kokoro, what you
say is heard by Voice Operator's hands-free (on-device Parakeet by default) and
handed to that agent, and you can talk over a reply to cut it off. The terminal
doesn't need to be in front, or even visible. It works in Spaceterm or in any
ordinary terminal.

It is built for one session at a time, for example vibe-coding a game in one
session while you play it.

## Requirements

- macOS on Apple Silicon, with a **Voice Operator that has voice mode** running:
  local API version 18, the first release after October 29, 2026, or a build
  of this repo. `voice-mode` tells you if yours is older.
- Kokoro installed from Voice Operator's **Text to Speech** menu, so replies can be spoken.
- **A headset: AirPods or a wireless headset.** Voice Operator can't hear you
  over its own voice on the Mac's speakers, so on speakers you can't interrupt
  a reply. Its echo-cancellation experiment for speakers isn't fully tested.
- A recent Claude Code. It was built and tested on 2.1.310, and needs
  `asyncRewake` hooks.

## Install

From Claude Code:

```
/plugin marketplace add chriswa/voiceop
/plugin install single-agent-voice-mode@voiceop
```

On Claude Code 2.1.275 or later you can do both in one step:
`/plugin install single-agent-voice-mode --marketplace chriswa/voiceop`.
Start a new Claude Code session afterwards so the hooks load. Updates come
with Voice Operator releases, because the plugin carries the app's version:
`/plugin marketplace update voiceop`.

To try it from a checkout instead:
`claude --plugin-dir ~/voiceop/claude-plugin/single-agent-voice-mode`.

## Use

| You | What happens |
| --- | --- |
| `/single-agent-voice-mode:start` | Voice mode attaches to **this** session. Voice Operator takes hands-free (from Spaceterm, if it had it), plays its "ready" tones, and the agent says hello. |
| `/single-agent-voice-mode:start jarvis` | The same, with **jarvis** as the trigger word instead of **claude**. A second word picks a Kokoro voice, such as `jarvis bf_emma`. |
| *"Claude, make the jump a bit higher."* | Hands-free hears the trigger word and takes down what you say until you've finished. The agent gets it as your message, and its answer is spoken. |
| *(just keep talking)* | For a short while after each reply you don't need the trigger word. After that, say "Claude" again. |
| *(talk over a reply)* | The reply stops, and the agent is told how much of it you heard. |
| *(speak while it works)* | Your words reach the agent at its next tool call, so you can redirect it mid-task. |
| *"Turn hands-free voice chat off"* | The agent turns voice mode off (`voice-mode stop`) and goes back to text. |
| *"Let me turn this off"* or *"Claude, shutdown"* | Voice Operator turns it off itself. |
| *"Stop listening"* | Only closes the conversation window. Say "Claude" to start again. |
| `/single-agent-voice-mode:stop` | Turns it off from the keyboard. So does **Turn Off Claude Voice Mode** in Voice Operator's menu. |
| `/single-agent-voice-mode:status` | Says whether it's on, for which session, and what hands-free is doing. |

While voice mode is attached, Voice Operator's menu shows
**Claude Voice Mode: \<project\>**. Permission prompts are read aloud,
because you may not be looking at the terminal. You still answer them at the
keyboard.

### Spaceterm

Voice mode and Spaceterm share the Mac's hands-free, and whichever turned it on
last has it. Starting voice mode takes hands-free from Spaceterm, and Spaceterm's
button goes off quietly. Turning Spaceterm's hands-free back on takes it back:
voice mode detaches, and the session is told the next time you type in it.
Spaceterm keeps its "Control" trigger word and voice mode uses "Claude", so it is
always clear which one you're talking to.

### One session at a time

Starting voice mode in a second session moves it there, and the first session
is told. Voice mode also lets go when its session ends, including when the
terminal is closed or `claude` crashes. It survives a Voice Operator restart
and follows the session through `/clear` and compaction.

## How it works

Voice Operator does the listening, speaking and deciding. The plugin only
carries messages to it, through Voice Operator's loopback API (`/v1/voice-mode/…`):

- **`Stop` hook** (`asyncRewake`): speaks the agent's final message, then waits
  in the background for you to say something. It exits with code 2 and your
  words, which wakes the agent with them as its next turn.
- **`PostToolUse`**: hands over anything you said while the agent was working.
- **`PreToolUse`** (Bash): pre-approves voice mode's own controls (`voice-mode
  stop`, `status`, and `say` with a single-quoted argument or a quoted
  heredoc) while it is attached, so "turn it off" works with nobody at the
  keyboard. No other command is approved.
- **`UserPromptSubmit`, `SessionStart`, `SessionEnd`, `Notification`**: tell the
  session if voice mode ended under it, give the rules back after compaction or
  `/clear`, let go when the session ends, and read permission prompts aloud.
- **`voice-mode`** (in `bin/`, on the agent's PATH): `start`, `stop`, `status`,
  and `say` for a short spoken heads-up mid-turn.
- **`voice-mode.md`**: the rules the agent follows while voice mode is attached,
  such as writing short replies meant to be heard. It's given to the agent only
  when voice mode attaches, and again after compaction.

Each hook exits immediately when voice mode isn't attached, so sessions without
it pay only for a file check.

## Privacy

What you say goes to Claude, the same as anything you type. Voice Operator's
**incognito mode** refuses to attach voice mode, and turning incognito on ends
it.

## Troubleshooting

- `voice-mode status`, or `curl -s 127.0.0.1:<port>/v1/voice-mode` (the port is
  in `~/Library/Application Support/VoiceOperator/speech-service.json`).
- `~/Library/Logs/VoiceOperator.log`: look for lines starting `voice mode:` and `hands-free:`.
- `~/Library/Application Support/VoiceOperator/hands-free/decisions.jsonl` has
  every hands-free decision, with the audio it was made on.
- If nothing is heard, check whether Spaceterm took hands-free back, or
  whether you're on speakers. While Voice Operator talks through speakers,
  hands-free doesn't listen.
