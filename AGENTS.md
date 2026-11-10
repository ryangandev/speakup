# SpeakUp

SpeakUp (working codename) is a speaking coach for deliberate practice.
Ryan records short solo answers, gets direct feedback on fluency and structure, re-records the same prompt, and sees what changed.
It has an iPhone app, written in SwiftUI, and an analysis server that runs on Ryan's home Mac mini.
v1 is English, work scenarios, used only by Ryan.

Milestone 1 (home practice) is built and runs end to end in the simulator, simplified on 2026-11-09 to one loop: pick a topic and length, record, report; it has not run a take on a real iPhone yet.
Milestone 2 (driving mode) is built but set aside and hidden in the app; on a real iPhone it did not yet hear short answers.
`server/` holds the analysis server (store, pipeline worker, API, coaching, analysis) and the speech-to-text bake-off; `tools/apple-transcribe/` is the Apple engine for the bake-off.
`ios/` holds the iPhone app (SwiftUI, iOS 26 or later); start from [ios/AGENTS.md](ios/AGENTS.md).
What is decided, what is open and what comes next is in [docs/status.md](docs/status.md).

## Start here

1. Check the branch, working tree and recent commits.
2. Read [docs/README.md](docs/README.md) to route the request, then read only the section it points to.

Do not read every doc by default.

## Commands

From `server/` (Python, managed by `uv`):

- `uv sync --extra crisper --extra qwen` installs everything, including local CrisperWhisper (English) and Qwen3-ASR (Chinese).
- `uv run pytest` runs the tests; `uv run ruff format` and `uv run ruff check` format and lint.
- `uv run speakup-bakeoff --help` runs the bake-off; the procedure is in [docs/bakeoff.md](docs/bakeoff.md).
- `uv run speakup-server` runs the analysis server on 127.0.0.1; it needs `SPEAKUP_API_TOKEN` (32 characters or more) in `server/.env`. Operating it is in [docs/server.md](docs/server.md).
- `uv run python -m speakup.coaching <analysis.json> --prompt "..." [--dry-run]` coaches one take, for iterating on the coaching prompt; `--dry-run` prints the request and needs no key.
- `SPEAKUP_UPDATE_SNAPSHOTS=1 uv run pytest tests/test_coaching_request.py` accepts an intended change to the coaching request snapshots.

From `ios/`: `xcodebuild test -project SpeakUp.xcodeproj -scheme SpeakUp -destination 'platform=iOS Simulator,name=<simulator>' -derivedDataPath build/DerivedData` runs the unit tests; `-scheme SpeakUpUITests` runs the screen walkthrough against the in-app mock server, and its `RealServerTests` runs one practice loop against a running server. Details are in [ios/AGENTS.md](ios/AGENTS.md).

From the repository root: `swift build -c release --package-path tools/apple-transcribe` builds the Apple engine.

## Rules that fail silently when broken

- Transcription must stay verbatim: never use an engine or setting that removes fillers, repetitions or false starts, because those are what the app measures. See [Speech to text](docs/architecture.md#speech-to-text).
- Driving mode never asks for a glance or a touch once a session starts. See [Driving mode](docs/product.md#driving-mode).
- Coaching tone is direct and covers strengths and problems, but caps what it flags. See [Feedback](docs/product.md#feedback).
- Keep API keys and the server token in ignored files only, and never print them. See [Configuration](docs/architecture.md#configuration).
- Never commit anything under `data/`: it holds Ryan's recordings and transcripts.
- Recordings contain Ryan's work content. Do not add a new service that receives audio or transcripts without updating [Data and privacy](docs/architecture.md#data-and-privacy).
- Before writing code that calls Claude, load the `claude-api` skill for current model IDs and API usage.
- The iOS app builds to the Server API contract in [architecture.md](docs/architecture.md#server-api); its JSON examples are copied verbatim into `ios/SpeakUpTests/Fixtures/`, so a contract change updates both.

## Keeping docs current

Update the doc that owns a fact in the same commit that changes it.
Ownership rules are in [docs/README.md](docs/README.md).
