# Hands-Free

A Claude Code plugin for talking with **one** Claude Code session hands-free,
through [Voice Operator](../../README.md). You type `/handsfree` in the session,
then put the keyboard down: the agent's replies are spoken by Kokoro, what you
say is heard by Voice Operator's hands-free (on-device Parakeet by default) and
handed to that agent as your own prompt, and you can talk over a reply to cut it
off. A soft sonar plays while the agent's main thread is working. The terminal
doesn't need to be in front, or even visible. It works in Spaceterm or in any
ordinary terminal.

It is built for one session at a time, for example vibe-coding a game in one
session while you play it.

## Requirements

- macOS on Apple Silicon, with a **Voice Operator that has voice mode** running:
  local API version 18, the first release after October 29, 2026, or a build
  of this repo.
- Kokoro installed from Voice Operator's **Text to Speech** menu, so replies can be spoken.
- **A headset: AirPods or a wireless headset.** Voice Operator can't hear you
  over its own voice on the Mac's speakers, so on speakers you can't interrupt
  a reply. (The sonar is no problem: hands-free listens through it.) Its echo-cancellation experiment for speakers isn't
  fully tested.
- Claude Code with function hooks (mods). It was built and tested on 2.1.310.

## Install

At the prompt of a Claude Code session:

```
/plugin install handsfree --marketplace chriswa/voiceop
```

Answer `y` to add the marketplace, then pick a scope (user is the usual one).
From a shell: `claude plugin install handsfree --marketplace chriswa/voiceop`.
Updates come with Voice Operator releases, because the plugin carries the app's
version: `/plugin marketplace update voiceop`.

To try it from a checkout instead:
`claude --plugin-dir ~/voiceop/claude-plugin/handsfree`.

## Use

| You | What happens |
| --- | --- |
| `/handsfree` | Hands-free attaches to **this** session. Voice Operator takes hands-free (from Spaceterm, if it had it), plays its "ready" tones and says "Listening". Run it again to turn it off. |
| `/handsfree on jarvis` | Turns it on with **jarvis** as the trigger word instead of **claude**. A further word picks a Kokoro voice, such as `/handsfree on claude bf_emma`. |
| *"Claude, make the jump a bit higher."* | Hands-free hears the trigger word and takes down what you say until you've finished. It reaches the agent as your own prompt, and the agent's answer is spoken. "Clod" and "clawed" count as "Claude", since that's how speech recognition often writes it. |
| *(just keep talking)* | For a short while after each reply you don't need the trigger word. After that, say "Claude" again. |
| *(talk over a reply)* | The reply stops, and the agent is told how much of it you heard. |
| *(a soft sonar)* | The agent's main thread is working. It's asked to hand long jobs to background subagents, so the sonar stays short and it stays free to talk. |
| *(speak while it works)* | Your words reach the agent with its next tool result, so you can redirect it mid-task. |
| *"Turn hands-free voice chat off"* | The agent turns hands-free off with its `stop` tool and goes back to text. |
| *"Let me turn this off"* or *"Claude, shutdown"* | Voice Operator turns it off itself. |
| *"Stop listening"* | Only closes the conversation window, with no warning sounds for other speech until you say "Claude" again. Said on its own, Voice Operator does it; inside a longer sentence, the agent does it with its `stop_listening` tool. |
| `/handsfree off` | Turns it off from the keyboard. So does **Turn Off Claude Hands-Free** in Voice Operator's menu. |
| `/handsfree status` | Says whether it's on, for which session, and what hands-free is doing. |

While it's on, a line above the prompt shows what hands-free is doing:
**Say “Claude” first** (the trigger word is needed), **Keep talking…** (the
conversation window is open), **Listening…** while you speak, and **working**
while the agent's main thread is busy. It goes when hands-free is off. Voice
Operator's menu shows
**Claude Hands-Free: \<project\>**. Permission prompts are read aloud,
because you may not be looking at the terminal. You still answer them at the
keyboard.

### Spaceterm

Hands-free in Claude Code and Spaceterm share the Mac's hands-free, and
whichever turned it on last has it. `/handsfree` takes it from Spaceterm, and
Spaceterm's button goes off quietly. Turning Spaceterm's hands-free back on
takes it back: this plugin detaches, and the session is told the next time you
type in it. Spaceterm keeps its "Control" trigger word and this plugin uses
"Claude", so it's always clear which one you're talking to.

### One session at a time

Turning hands-free on in a second session moves it there, and the first session
is told. It also lets go when its session ends, including when the terminal is
closed or `claude` crashes. It survives a Voice Operator restart and follows
the session through `/clear` and compaction.

## How it works

The plugin is a mod: one hooks module, `hooks/register.ts`, on Claude Code's
function-hooks API. Voice Operator does the listening, speaking and deciding;
the mod carries messages to it over Voice Operator's loopback API
(`/v1/voice-mode/…`):

- **`/handsfree`** (`$.command.register`) attaches or detaches the session.
- **`turn.start` / `turn.complete`** on the main thread start the sonar, then
  stop it and speak the answer.
- **Listening:** while the main thread is idle, the mod long-polls Voice
  Operator for what you say next and submits it with `$.prompt.submit({ text,
  asUser: true })`. That makes it a real prompt in your own words, not a
  notification or a hook message.
- **`tool.call`:** what you say while the agent works goes in with the next
  tool result.
- **`prompt.compose`:** while hands-free is on, the system prompt carries
  `hands-free.md`, the agent's rules for this mode: short replies written to
  be heard, and long work in background subagents. Being in the system prompt
  is what lets the rules outlive compaction and go away when hands-free is off.
- **Tools:** `mcp__handsfree__stop`, `mcp__handsfree__stop_listening` and `mcp__handsfree__say`, registered when
  hands-free first turns on and allowed without a prompt.
- **`prompt.submit`, `classic.Notification`, `session.end`:** tell you, the next
  time you type, if hands-free went off under the session; read permission
  prompts aloud; and let go when the session ends.

## Privacy

What you say goes to Claude, the same as anything you type. Voice Operator's
**incognito mode** refuses to turn hands-free on, and turning incognito on ends
it.

## Troubleshooting

- `/handsfree status`, or `curl -s 127.0.0.1:<port>/v1/voice-mode` (the port is
  in `~/Library/Application Support/VoiceOperator/speech-service.json`).
- `~/Library/Logs/VoiceOperator.log`: look for lines starting `voice mode:` and `hands-free:`.
- `~/Library/Application Support/VoiceOperator/hands-free/decisions.jsonl` has
  every hands-free decision, with the audio it was made on.
- If nothing is heard, check whether Spaceterm took hands-free back, or
  whether you're on speakers. While Voice Operator talks through speakers,
  hands-free doesn't listen.
- `claude --debug` logs a line for each mod hook that failed.
