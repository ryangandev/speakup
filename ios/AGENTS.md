# SpeakUp iOS app

The iPhone app: native SwiftUI, iPhone only, iOS 26 or later, Swift 6 language mode with strict concurrency.
What it does is in [docs/product.md](../docs/product.md); how it talks to the server is the contract in [docs/architecture.md](../docs/architecture.md#server-api).
Build to that contract: never change the docs to fit the code.

## Commands

Run from `ios/`.
Use one simulator and one `xcodebuild` at a time.

- Build: `xcodebuild build -project SpeakUp.xcodeproj -scheme SpeakUp -destination 'platform=iOS Simulator,name=<simulator>' -derivedDataPath build/DerivedData`
- Test: `xcodebuild test -project SpeakUp.xcodeproj -scheme SpeakUp -destination 'platform=iOS Simulator,name=<simulator>' -derivedDataPath build/DerivedData`
- One suite: add `-only-testing:SpeakUpTests/ProcessingControllerTests`.
- Screen walkthrough: the same `test` command with `-scheme SpeakUpUITests`. It drives every home-mode screen against the mock server and attaches a screenshot of each to the result bundle. Set `TEST_RUNNER_SHOT_DIR=<dir>` to also write the PNGs there, and `TEST_RUNNER_SHOT_SUFFIX=<name>` to tell runs apart. Switch appearance and text size between runs with `xcrun simctl ui <udid> appearance dark` and `xcrun simctl ui <udid> content_size accessibility-large`. It is slow (several minutes), so it is a separate scheme, not part of `SpeakUp`'s tests.
- Real server: `-scheme SpeakUpUITests -only-testing:SpeakUpUITests/RealServerTests` runs one practice loop (settings, take, report, retry, comparison) against a running `speakup-server`. Pass `TEST_RUNNER_SPEAKUP_SERVER=http://127.0.0.1:<port>`, `TEST_RUNNER_SPEAKUP_TOKEN=<token>` and `TEST_RUNNER_SPEAKUP_MIC_FILE=<a speech WAV>`; without them it is skipped. A speech WAV can be made with `say -o take.wav --data-format=LEI16@16000 "..."`.
- Install and launch on a booted simulator: `xcrun simctl install <udid> build/DerivedData/Build/Products/Debug-iphonesimulator/SpeakUp.app`, then `xcrun simctl launch <udid> dev.ryangan.speakup <arguments>`.

`build/` is ignored.
There is no development team in the project: simulator builds need none, and signing for a device is set locally in Xcode, not committed.

## Debug launch arguments

Debug builds only; none of this exists in Release.

- `-debug.useMockServer YES` runs against the in-app mock server (`Mock/`), which simulates the whole pipeline with no Mac mini.
- `-debug.mockScenario <name>` picks a scenario: `normal`, `coachingUnavailable`, `coachingFailed`, `noSpeech`, `processingFails`, `uploadFails`, `slowProcessing`, `unreachable`.
- `-resetState` clears the phone's practice state at launch. The mock server keeps its data in memory, so it starts fresh on every launch anyway; pass `-resetState` with it so the phone does not point at takes the mock no longer has.
- `-slowAfter <seconds>` shortens the "Taking longer than usual" threshold.
- `-debug.syntheticMicrophone` records a generated tone instead of the microphone. Simulators usually have no audio input, so recording fails there without it.
- `-debug.microphoneFile <path>` records an audio file on the Mac instead, played in real time and looped, so the server gets real speech to transcribe.
  Simulated input of either kind skips the microphone permission prompt.
- In a drive, either flag replaces the drive engine's input with `ScriptedMicrophone` (`Drive/DriveDebug.swift`): silence in real time, with the `-debug.microphoneFile` clip played once each time a take opens, so a WAV that ends with a spoken "done" drives a take.
  The simulator's input node reports 0 Hz and cannot be tapped, so a drive there needs one of these flags.
- `-debug.recognizerScript <json>` replaces a drive's speech recognizer with `ScriptedRecognizer` (`Drive/ScriptedRecognizer.swift`), which hears scripted words on the drive clock, such as `{"recording": ["so that is my answer@0.5 done@4.2"], "betweenTakes": ["again@0.5"]}`.
  Each listening window takes the next line of its mode, and `answer@0.5` starts the phrase that ends with it 0.5 s into the window.
  A window starts at the time given to `listen`, or at the drive clock if `listen` comes later, which is about when the scripted microphone starts the take clip.
  The simulator has no recognizer for commands (`SpeechTranscriber` is unsupported and `DictationTranscriber` has no model), so a drive there needs this flag; an invalid script makes the drive report commands unavailable.
- `-serverAddress <url>` sets the server address for this launch.

Settings shows the same mock toggle and scenario picker in Debug builds.

## Layout

- `App/`: the app entry, `AppModel` (settings, API client, store, server status) and `RootView` (tabs, sheets, the take flow cover).
- `Models/`: Codable types for every contract shape. `Networking/`: the `SpeakUpAPI` protocol and its HTTP client.
- `Audio/`: the `AVAudioEngine` recorder, the WAV writer and playback.
- `Drive/`: driving mode: the drive audio core (`DriveAudio`: one engine for the whole drive, the take gate and trim, the driving audio session), command recognition (`SpeechCommandRecognizer` on `SpeechAnalyzer`, its pure decisions in `CommandRecognition.swift`, the Debug `ScriptedRecognizer`), command spotting and the spoken script.
  `tools/drive-commands` runs the recognition files on the Mac against real speech; keep them free of iOS-only APIs.
- `Practice/`: the phone's local store, upload sync, the polling state machine and transcript layout.
- `Screens/`: one file per screen group. `Settings/`: settings and the Keychain.
- `Theme/`: every color, font, spacing value and transcript mark, plus reusable components.
- `Mock/`: the Debug-only mock server.
- `SpeakUpTests/Fixtures/`: the JSON examples from the contract, copied verbatim.
- `SpeakUpUITests/`: the screen walkthrough.

The project uses synchronized folders: a new file under `SpeakUp/`, `SpeakUpTests/` or `SpeakUpUITests/` is in its target with no project edit.

## Rules that fail silently when broken

- Screens never use a literal color, font, spacing or corner radius: they go through `Theme` and the components in `Theme/Components.swift`, so the final visual design can replace them without touching logic.
- Contract enums are `OpenEnum` structs, not Swift enums, so a value the server adds later decodes instead of failing the whole response. Every `switch` over one needs a default that does something sensible.
- Ids the app creates are lowercase UUIDs from `IDs.make()`, and every create is an idempotent `PUT`, so retries are always safe. Never retry with a new id.
- A take is written to the phone before it is uploaded and is only dropped once the server has it. Do not delete take audio anywhere except `PracticeStore.pruneFinishedSessions`.
  The exceptions are files the store never received: a recording discarded before it is kept (home Cancel), and a drive take that `DriveAudio` reports as `.empty` (no input reached it, or the cut left no audio), which it deletes itself.
- The server token lives in the Keychain only. Never log it, put it in `UserDefaults` or show it unmasked.
- Mock code is wrapped in `#if DEBUG`. Anything that references it must be too, or Release will not build.
- When a contract example changes, update its fixture in `SpeakUpTests/Fixtures/` verbatim; the decoding tests are only as good as the fixtures.
- Check new screens in light and dark mode and at a large Dynamic Type size.
