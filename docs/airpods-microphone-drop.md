# The AirPods music drop after a dictation (2026-10-29/30)

**Status: macOS behaviour, not ours. Do not reopen it until Apple ships a
macOS fix** — the likeliest being AirPods high-quality recording
(`bluetoothHighQualityRecording`, WWDC25) coming to the Mac. Check that first.

## The symptom

With AirPods as both output and input, and the microphone *not* held open
(neither "Keep Microphone Always On" nor "Only When Using AirPods (Bluetooth)",
and not hands-free): a Fn dictation ends, the music comes back, and **about 2 s
after the microphone closed** it drops out for about half a second, then comes
back. At the start of a dictation there is no drop (the AirPods' microphone
opens at 48 kHz, their high-quality mode, without disturbing playback), but the
first ~300 ms after opening is a switch in progress, in which the start chirp and
the first words could be lost.

## What causes it

About **2.15 s** after *any* app stops recording from the AirPods, macOS tears
down their recording link: a full reconfiguration of both the input and output
devices — `cfgb` … `cfge` (configuration begin/end), `scon` (stream
configuration), Bluetooth-specific properties (`sdel`, `bdsp`, `nrle`, `dcat`,
`avap`, `btfo`, `avcp`), then a burst of output stream-format changes (`htac`,
`htst`, `spfi`, …). The timing is the same to within ~20 ms every time, whatever
the app does, whenever it unmutes, and whatever API opened the microphone.
macOS holds the link 2 s in case recording resumes; nothing found changes that.

## Every way of opening the microphone, tried (`HeadsetProbe`)

Each opened the default input (the AirPods) for 1.5 s, closed it, and watched
every Core Audio property change on the default input and output devices and on
the system's device list (`DeviceSettleWatch`, which the app still uses). Run
inside the app (the loopback API) so it had the microphone permission — run
from a terminal, every way heard only zeros, and the AudioQueue then did not
switch the link at all, which looked like a fix and was not. The user listened
for the drop, with a chirp marking the open and another the close.

| Way | Heard audio | Rebuild at close | Drop heard |
|---|---|---|---|
| `AVAudioEngine` input tap, `stop()` (what `AudioRecorder` does) | yes | +2145–2161 ms | yes |
| `AVAudioEngine`, `pause()` instead (keeps its private aggregate device) | yes | +2157 ms | yes |
| HAL output unit, input-only, on the device itself (no aggregate) | yes | +2150 ms | yes |
| `AudioQueue` input (no engine, no output) | yes | **none in the properties** — the input just stops running at +2110 ms | **yes, ~2 s after close** |
| `AVCaptureSession` (AVFoundation's capture stack) | yes | +2164 ms | yes |

So it is not AVAudioEngine's private aggregate device (pausing keeps it, and the
HAL unit and AudioQueue never make one; no aggregate shows coming or going in the
system's device list either), not the output mute, not ducking (none on
Bluetooth), not the engine's input+output pairing. The probe was removed once
done; it is in git history (`da7b03f`, `12e5e74`, `bcecb4d`, `667db08` —
`Sources/VoiceOperator/Audio/HeadsetProbe.swift`, `--headset-probe [way]`, and
`POST /v1/debug/headset-probe?way=&cues=1`) if it is ever needed again.

## What else was tried, in order

1. **Start cue on the first non-zero buffer** (`AudioRecorder.onFirstSound`, still
   there): useless on these AirPods — real sound arrives in the first buffer,
   ~140 ms in, while the switch is still under way.
2. **Start cue once the devices go quiet** (`DeviceSettleWatch.whenQuiet`, 250 ms,
   2 s cap): **works** — kept. The cue lands ~160 ms after the first audio, and
   the first words get through.
3. **Unmute 700 ms after the microphone closes** (fixed wait): too early.
4. **Unmute on 300 ms of device quiet**: sometimes before anything happened.
5. **Unmute after the first output format burst (`out:spfi`) + 400 ms**: the
   bursts at ~0.4 s and ~0.75 s turned out to be caused by our own unmute and
   chirps, not the switch.
6. **Unmute after the reconfiguration ends (`out:cfge`)**: **works** with "Mute
   System Audio While Dictating" on — kept. The music stays muted through the
   drop, so it is never heard; it comes back ~2.2 s after key-up.
7. **Closing sounds after that unmute** (0, 250, 500 ms later): never heard — the
   reconfiguration's tail, and our own playback starting, swallow them. Kept only
   for the muted case; with nothing muted they play at key-up (they did before).
8. **Mute off** ("Mute System Audio While Dictating" unticked): the drop is still
   there at ~2 s — so the mute was never the cause.

## On the web

Nobody has a way to open and close a Bluetooth microphone on a Mac without the
playback disruption; everyone avoids the headset's microphone instead:

- Wispr Flow shows an "AirPods aren't ideal for dictation" tip and recommends the
  built-in microphone (its bundle, `air_pods_warning_*` strings).
- xflow, an open-source dictation app, plans to record from the built-in mic when
  the input is Bluetooth: https://github.com/itsmrad/xflow/issues/96
- InputGuard and InputDeviceGuard exist only to keep macOS's input off Bluetooth
  headsets: https://github.com/thisisjsimon/InputGuard,
  https://github.com/Pototoooo/InputDeviceGuard
- Capo's developer on AVAudioEngine and AirPods:
  https://supermegaultragroovy.com/2021/01/28/more-on-avaudioengine-airpods/
- Forum threads, same advice:
  https://forums.macrumors.com/threads/very-low-quality-playback-on-macos-good-on-ios.2353222/,
  https://swissmacuser.ch/airpods-suddenly-change-to-low-quality-audio-in-macos/
- Apple's AirPods high-quality recording mode (WWDC25 session 251,
  https://developer.apple.com/videos/play/wwdc2025/251/) — a separate, more
  reliable link for AirPods recording — is iOS-only:
  `AVCaptureSession.configuresApplicationAudioSessionForBluetoothHighQualityRecording`
  is "unavailable in macOS" at compile time. **This is the thing to watch for.**

## What to use instead

- **Only When Using AirPods (Bluetooth)** — the hold (`AudioRecorder.setAlwaysOn`):
  the microphone is never closed while the AirPods are the output, so no drop,
  no waits; the microphone indicator stays on.
- **Use the Mac's Microphone with AirPods (Bluetooth)**
  (`AudioPreferences.macMicrophoneWithHeadsets`): the AirPods' microphone is never
  opened; the MacBook's records instead.
- A "linger" (keep the microphone open a few minutes after each dictation) was
  offered and declined.

With neither, the arbiter's headset path (`LiveDictation.headsetSwitches`) cues
after the devices settle at the start and, if it muted, stays muted until the
reconfiguration ends — see DESIGN.md "Holding the microphone open".
