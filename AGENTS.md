# SpeakUp

SpeakUp (working codename) is a speaking coach for deliberate practice.
Ryan records short solo answers, gets direct feedback on fluency and structure, re-records the same prompt, and sees what changed.
It has an iPhone app, written in SwiftUI, and an analysis server that runs on Ryan's home Mac mini.
v1 is English, work scenarios, used only by Ryan.

The repository is in milestone 0: the only code is the speech-to-text bake-off in `server/` and `tools/apple-transcribe/`.
What is decided, what is open and what comes next is in [docs/status.md](docs/status.md).

## Start here

1. Check the branch, working tree and recent commits.
2. Read [docs/README.md](docs/README.md) to route the request, then read only the section it points to.

Do not read every doc by default.

## Commands

From `server/` (Python, managed by `uv`):

- `uv sync --extra crisper` installs everything, including local CrisperWhisper.
- `uv run pytest` runs the tests; `uv run ruff format` and `uv run ruff check` format and lint.
- `uv run speakup-bakeoff --help` runs the bake-off; the procedure is in [docs/bakeoff.md](docs/bakeoff.md).

From the repository root: `swift build -c release --package-path tools/apple-transcribe` builds the Apple engine.

## Rules that fail silently when broken

- Transcription must stay verbatim: never use an engine or setting that removes fillers, repetitions or false starts, because those are what the app measures. See [Speech to text](docs/architecture.md#speech-to-text).
- Driving mode never asks for a glance or a touch once a session starts. See [Driving mode](docs/product.md#driving-mode).
- Coaching tone is direct and covers strengths and problems, but caps what it flags. See [Feedback](docs/product.md#feedback).
- Keep API keys and the server token in ignored files only, and never print them. See [Configuration](docs/architecture.md#configuration).
- Never commit anything under `data/`: it holds Ryan's recordings and transcripts.
- Recordings contain Ryan's work content. Do not add a new service that receives audio or transcripts without updating [Data and privacy](docs/architecture.md#data-and-privacy).
- Before writing code that calls Claude, load the `claude-api` skill for current model IDs and API usage.

## Keeping docs current

Update the doc that owns a fact in the same commit that changes it.
Ownership rules are in [docs/README.md](docs/README.md).
