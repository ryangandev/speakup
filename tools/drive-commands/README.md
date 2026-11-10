# drive-commands

Runs the iPhone app's voice-command recognition on the Mac, with Apple's real on-device recognizer, over spoken clips.
The iOS simulator has no recognizer for commands, so this, plus a check on a device, is what tests the real one.

It runs the app's own code: `Sources/drive-commands/Shared/` holds symbolic links to `CommandSpotter.swift`, `CommandRecognition.swift`, `SpeechCommandRecognizer.swift` and `ScriptedRecognizer.swift` in `ios/SpeakUp/Drive/`.
`DriveAudio.swift` needs iOS's audio session, so the tool has its own copy of the one type it needs from it, `DriveAudioBuffer`.

Each clip is fed as the phone's input tap would feed it: 4096-frame buffers at 48 kHz, in real time, starting 7 s into a drive clock (1 s of silence first, 4 s after).
A `SpeechCommandRecognizer` hears it, a `CommandSpotter` listens in the clip's mode, and the tool checks the command against the clip's expectation.
For a "done", the cut must keep the whole answer (the cut minus the 0.1 s margin is after the answer ends) and at most 0.1 s of the command; true times come from the clip's audio level.

## Run

Needs macOS 26 or later with the English speech assets (the tool installs them if missing).

```sh
tools/drive-commands/make-clips.sh
swift run -c release --package-path tools/drive-commands drive-commands
```

- `--transcriber speech|dictation|both` picks the recognizer; `speech` (`SpeechTranscriber`, the app's choice) is the default.
- `--only <clip>` runs one clip; `--verbose` prints every final result and the spotter's event; `--trace` prints every update the spotter receives.

## Replay a phone run

A Debug build launched with `-debug.recognizerCapture` writes what its recognizer was fed and what it did to the app's temporary directory: `recognizer-input.caf` and `recognizer-trace.txt` (see `RecognizerCapture` in `SpeechCommandRecognizer.swift`).
They hold Ryan's speech, so copy them only to a scratch folder outside the repository:

```sh
xcrun devicectl device copy from --device <udid> --domain-type appDataContainer --domain-identifier com.rystudio.speakup --source tmp --destination <scratch>/phone
swift run -c release --package-path tools/drive-commands drive-commands --replay <scratch>/phone/tmp
```

The replay feeds the phone's input in real time, opens and closes the listening windows when the phone did, prints every spotter update and event, and writes the Mac's own trace as `mac-recognizer-trace.txt` beside the phone's, to compare line by line.

It takes about 3 minutes per transcriber and exits non-zero when a clip fails.
The clips and what each must give are in `make-clips.sh`; `clips/` is generated and ignored.
They include speech shortly after a command ("done [0.7 s] actually, one more thing", "stop [0.5 s] at the next exit please"), which a recognizer that claims silence too early mistakes for a command.

## Results on macOS 27.0.1

`SpeechTranscriber` passes all 25 clips, including the five nervousness answers ("one", "two", "three", "five", "skip").
It wrote a lone "three" as a volatile "3" and a final "Three."; the recognizer lines the two up as the same word.
Each "done" was cut within 0.21 s of where it was said, and the spotter acted 3.3 to 3.8 s after the speech ended (the 1.2 s silence rule and a 0.3 s margin, 1.5 s for the recognizer to report any words in it, then 0.3 s to settle); between takes, it acted 1.7 to 3.5 s after the speech ended.

`DictationTranscriber` is not used by the app; on the first 12 clips it failed 2:
`thinking-pause` (it never finalizes the last "done") and `pause-done` (its "done" starts 0.36 s late, so the take keeps part of it).
It also invents a word ("no") when silence is finalized.

A Mac is not a phone: microphone, noise and model versions differ, so the device check still decides the thresholds.
