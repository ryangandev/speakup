# SpeakUp

SpeakUp (working codename) is a speaking coach for deliberate practice.
You record a short spoken answer, get direct feedback on fluency and structure, record the same prompt again, and see what changed.
v1 is English, focused on work conversations, and built for one person.

## How it works

- **iPhone app** (SwiftUI, iOS 26 or later): records takes, uploads them, and shows reports and comparisons.
- **Analysis server** (Python, FastAPI) on a home Mac, reached over Tailscale: verbatim speech to text with CrisperWhisper, rule-based analysis of fillers, blocks, restarts and repetitions, then coaching from Claude.
- **Practice:** pick a topic (a question by category, or your own) and a length, record, see the transcript and metrics as soon as the take is analyzed, then Claude's feedback; retry and compare.
- **Driving mode** (set aside for now, hidden in the app): fully hands-free.
  The app reads a question, you answer, say "done", and it reads the feedback aloud.

## Status

Home practice and driving mode are built and run end to end in the iOS simulator against the real server.
They have not run on a real iPhone yet.
Coaching needs an Anthropic API key; without one, the app reports metrics only.
Details are in [docs/status.md](docs/status.md).

## Repository

| Path | What |
|---|---|
| `ios/` | The iPhone app; see [ios/AGENTS.md](ios/AGENTS.md) |
| `server/` | The analysis server and the speech-to-text bake-off |
| `tools/apple-transcribe/` | Apple's speech engine for the bake-off |
| `tools/drive-commands/` | Checks driving-mode voice commands with the real recognizer on a Mac |
| `docs/` | Product, architecture, server operation and status; start at [docs/README.md](docs/README.md) |

## Running it

Server, from `server/`:

```bash
uv sync --extra crisper --extra qwen
```

```bash
uv run speakup-server
```

It needs `SPEAKUP_API_TOKEN` (32 characters or more) in `server/.env`; [server/.env.example](server/.env.example) lists every setting, and [docs/server.md](docs/server.md) covers running it on a Mac.

iOS unit tests, from `ios/`:

```bash
xcodebuild test -project SpeakUp.xcodeproj -scheme SpeakUp -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -derivedDataPath build/DerivedData
```

More commands, including the UI tests and the real-server tests, are in [AGENTS.md](AGENTS.md) and [ios/AGENTS.md](ios/AGENTS.md).
