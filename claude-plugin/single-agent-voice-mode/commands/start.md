---
description: Start hands-free voice chat with this session (Voice Operator)
argument-hint: "[trigger word] [kokoro voice]"
allowed-tools: Bash(voice-mode:*)
---
!`voice-mode start $ARGUMENTS`

If the output above says voice mode could not start, tell the user why in one
line of text and stop.

Otherwise, voice mode is now on for this session: follow the voice mode rules
above for as long as it stays attached. Greet the user with one short spoken
sentence that tells them you're listening and names the trigger word, then end
your turn so they can answer.
