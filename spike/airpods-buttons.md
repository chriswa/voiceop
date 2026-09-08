# AirPods stem presses as a dictation trigger — investigation, 2026-09-06

**Verdict: not achievable.** The AirPods microphone and the AirPods buttons are
mutually exclusive, and the app needs the microphone. Recorded here so nobody
spends another afternoon rediscovering it.

Hardware under test: `chriswa's AirPods`, vendor `0x004C` product `0x201B`,
the then-current macOS release, Voice Operator v0.1.27–v0.1.33.

---

## 1. What the hardware can express at all

There is no "AirPods tap API". The force sensor is interpreted **in the earbud's
own firmware** and sent to the host as ordinary Bluetooth AVRCP media commands
(`Services: HFP AVRCP A2DP AACP GATT ACL`). macOS never sees "double tap"; it
sees `Next Track`.

| Gesture | What can reach the Mac |
|---|---|
| single press | Play/Pause |
| double press | Next Track |
| triple press | Previous Track |
| press-and-hold | *nothing* — consumed by the earbud for Siri / noise control |
| stem swipe | volume, handled by the system |

Consequences that hold regardless of anything else:

- **Three discrete events, maximum.**
- **No press-down/press-up pair**, so no push-to-talk. Toggle semantics only.
- **No hold gesture available** — it never leaves the earbud.
- Distinguishing single from double costs a ~300–400 ms wait, which is felt.

## 2. The finding that kills it

**While the microphone is open, a stem press is not a media command.** Holding
the input open keeps the AirPods in the HFP voice profile, and in that profile
the stem is a call-control / noise-control button. Pressing it with the mic held
open produced a macOS notification to the effect of *"cannot control mic with
AirPods for ANC"* — the system claimed the press and failed to act on it. Double
and triple press afterwards did nothing at all; playback was unaffected.

So the app is itself the reason the presses vanish. And the exclusivity is not
escapable by design cleverness:

- Presses only become media commands with the mic **closed**.
- Opening the mic is the first thing a dictation does.
- Therefore a press could at best **start** a dictation and never **stop** one —
  the moment capture begins, the profile flips and the next press goes to call
  control. A press-to-start / key-to-stop hybrid is the ceiling, and it is worse
  than the existing key.

## 3. Routes for receiving media commands (for anything else that wants them)

Two were tested; the results are reusable.

**`MPRemoteCommandCenter` — works, with a caveat.** An `LSUIElement` agent that
plays no audio at all *can* become the Now Playing app: publish
`MPNowPlayingInfoCenter.default().nowPlayingInfo` (metadata only) plus
`playbackState = .playing`, register handlers, done. Verified — a keyboard
Next Track key was received and consumed. **No audio API is touched**, so this is
safe to run alongside the capture graph. The caveat is arbitration: Now Playing is
winner-take-all, whatever last published owns the commands, and there is no
"also deliver to me". Re-asserting on a timer to win it back is a real fight.

**Passive `NSSystemDefined` observation — dead.** A global monitor on
`.systemDefined` (subtype 8, `NX_KEYTYPE_PLAY`/`FAST`/`REWIND`) saw **0 of 6**
media events, including ones `MPRemoteCommandCenter` received in the same
instant. Bluetooth AVRCP does not reach that event stream on the current macOS release, and
neither, apparently, do the keyboard's own media keys. There is no way to observe
media commands without taking Now Playing away from whatever is playing.

**Private `MediaRemote.framework`** was not tried. Not signing/notarization
friendly and it breaks across releases.

## 4. Automatic ear detection generates phantom presses

Three `play`/`pause` commands arrived in one hour with nothing touched. The
pattern — `pause` with output on the speakers, `play` 2.5 s later with output on
the AirPods, `pause` again — is ear detection: out, in, out.

**These are indistinguishable from a single press.** Same command, no source
information. Any design mapping single-press to an action would fire it every
time an AirPod goes in or out of an ear. Double/triple press are clean, since ear
detection never generates `nextTrack`/`previousTrack`.

Turning off Automatic Ear Detection removes them, but it is a bad trade: it is
one switch for both ears, so removing *both* AirPods stops pausing too, and the
output no longer falls back to the Mac speakers — which is the very signal
`AppCoordinator.shouldKeepMicrophoneOpen` rides on (see §5).

## 5. Bluetooth audio facts learned the hard way

These cost the most time and are the most reusable.

- **A2DP and HFP are mutually exclusive.** Opening the AirPods mic forces the
  voice profile. It does not merely degrade playback — it **orphans the stream
  that was already running**. Spotify reported itself still playing into total
  silence, and neither pressing play nor restarting the track recovered it. The
  fix from outside is to switch the default output away and back.
- **`OutputMuter` is not a pause.** It sets `kAudioDevicePropertyMute` on the
  output device; the player keeps streaming into a muted device, so the stream is
  still live when the profile switch orphans it. This is *why* the failure looks
  the way it does. A real pause (stopping the stream before the switch) would
  survive it — untested, but it is the obvious mitigation if this is ever revisited.
- **Holding the mic open while music plays makes the device flap**, ~3.4 s per
  cycle, each cycle an audible cut. See DESIGN.md, "The rebuild must not answer
  its own notification" — `configurationChanged` now ignores self-inflicted
  changes and stands down after `maxRebuildsPerWindow` rebuilds.
  **Calibrate any such limiter against the slow flap**: the first attempt (4 in
  10 s) never tripped on a 3.4 s cycle and sat there doing nothing while the
  user's audio was destroyed.
- **When the hold-open rule engages seems to matter.** Toggling it on *mid
  playback* flapped; letting the output route establish with the rule already on
  settled in one step and then played stably for minutes. One observation, not a
  proven rule, but worth checking first if this is revisited.
- **CoreAudio can get stuck.** After a storm of `-10868`
  (`AUGraphParser::InitializeActiveNodesInInputChain`) the AirPods input went on
  delivering **digital silence** — recordings with `peak 0.0000` — while the
  device reported healthy and connected. Nothing in the app can clear it.
  Power-cycling the AirPods through their case fixed it.

## 6. Two traps for whoever works here next

**Never set `kAudioOutputUnitProperty_CurrentDevice` on an `AVAudioEngine` input
unit without rebuilding the engine.** Doing so leaves the engine holding a stale
format and **every subsequent `engine.start()` fails with -10868**, including
after the override is switched back off — the device selection persists in the
unit. This shipped in v0.1.31 and broke all dictation. Selecting the built-in mic
while AirPods are the output is otherwise an attractive idea (the headset never
enters HFP, so music is untouched and there is no codec stall to pre-empt); it
just needs a fresh `AVAudioEngine`, with the `AVAudioEngineConfigurationChange`
observer re-registered, around any device change.

**`defaults write` does not reach the running app.** `AudioPreferences` reads
live from `UserDefaults`, but the running process keeps its cached value and only
a relaunch picks up an external write. Twice this made a recovery look like it
had failed when the write had simply not landed. (Also: the domain is
`com.chriswa.voiceoperator`, not `com.chriswaddell.*`.) Anything that needs to be
settable from outside needs a loopback endpoint, not `defaults`.

## 7. How to re-run this

The probe used here has been removed (it lived in
`Sources/VoiceOperator/Audio/AirPodsButtonProbe.swift`, driven by a
`POST /v1/probe/media?seconds=N` route on `SpeechHTTPService`). To rebuild it:
register every `MPRemoteCommandCenter` command including the call-control ones,
publish now-playing metadata on a ~2 s timer, add a global `.systemDefined`
monitor, and stamp every logged event with the microphone state and the current
output device — the mic state is what separates the two Bluetooth profiles and
without it the log cannot be interpreted.

**Cheaper than any probe:** just watch the player. If a stem press pauses Spotify,
presses reach macOS; if nothing moves, they do not. No Now Playing contention, no
audio touched, and it answers the only question that matters first.
