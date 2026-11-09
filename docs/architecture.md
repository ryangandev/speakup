# Architecture

Status: planned design.
Only the speech-to-text layer and the M0 bake-off are built; other sections gain code paths as code lands.

## Code map

| Path | What it is |
| --- | --- |
| `server/` | Python package `speakup`, managed by `uv`; the future analysis server |
| `server/src/speakup/stt/` | Speech-to-text engines behind one interface: `Word`, `Transcript`, `Engine` in `__init__.py`, one module per engine, `registry.py` |
| `server/src/speakup/bakeoff/` | M0 bake-off: token normalization (`text.py`), alignment (`align.py`), scoring (`metrics.py`), reference pauses (`vad.py`), report and command line |
| `server/src/speakup/config.py` | Settings and secrets from the environment and `server/.env` |
| `server/tests/` | Unit tests |
| `tools/apple-transcribe/` | Swift command-line tool that runs Apple's `SpeechTranscriber` and prints JSON |
| `data/` | Ryan's recordings, transcripts and reports; ignored by git |

## System shape

```text
iPhone app (SwiftUI)                      Mac mini at home (analysis server)
  record take  ──── upload over Tailscale ───▶  1. speech to text (verbatim, word timestamps)
  local queue when offline                      2. acoustics (voice activity, pauses, pitch, volume)
  spoken prompts and feedback  ◀── report ────  3. disfluency detection (rules + LLM)
  visual report, history                        4. coaching (Claude, structured output)
                                                5. comparison with the previous take
                                                store: SQLite + audio files
```

The phone records and presents.
The Mac mini does all analysis and is the source of truth for recordings, reports and history.

Why this split:

- Analysis code (Python audio and ML libraries) runs where those libraries live, and Ryan can run local models on the Mac mini's GPU.
- Every stage is replaceable, so a better speech-to-text engine or coaching model can be swapped in without touching the app.
- One user, one server: no accounts, no cloud backend to run.

## iPhone app

- Swift and SwiftUI, iOS 26 or later, iPhone only.
  This matches Ryan's other apps and gives first-class access to audio sessions, Siri, App Intents, CarPlay and on-device speech.
- **Recording:** `AVAudioEngine`, mono, at least 16 kHz, kept as lossless or high-bitrate audio so pause timing is not smeared by compression.
- **Microphone in the car:** when the phone is connected to the car, iOS may route input to the car's hands-free microphone, which is often narrowband and noise-suppressed and may erase quiet fillers and short pauses.
  M0 tests this; if it hurts accuracy, the app prefers the iPhone's built-in microphone while playing audio through the car.
- **Voice commands** in driving mode ("done", "again", "next") use on-device `SpeechAnalyzer`, so they work without the network.
- **Spoken prompts and feedback:** `AVSpeechSynthesizer` with a premium voice first; a server-side voice can replace it later.
- **Offline queue:** takes are saved locally first and uploaded when the server is reachable.
- **Local cache:** SwiftData keeps sessions and reports for offline viewing; the server stays the source of truth.

## Analysis server

- Python, run with `uv`, FastAPI, as a `launchd` service on the Mac mini.
- **Network:** reachable only over Tailscale, plus a bearer token.
  It is never exposed to the public internet.
- **Storage:** SQLite for sessions, prompts, takes, reports and metrics; audio files on disk.
- **Jobs:** each take runs the pipeline as a background job; the app polls or streams progress.
- **Latency target:** spoken feedback within about 20 seconds of the end of a two-minute take in driving mode.
  M0 measures whether each engine meets it.

### Pipeline stages

Each stage has a narrow interface and writes its output to the take's record, so a stage can be rerun or replaced on its own.

1. **Speech to text:** audio in, verbatim words out, each with start and end time and confidence. See [Speech to text](#speech-to-text).
2. **Acoustics:** voice activity detection (Silero VAD) for silence spans, and Parselmouth (Praat) for pitch and intensity.
   Pauses come from the voice-activity track cross-checked against word gaps, because word gaps alone absorb breaths.
3. **Disfluency detection:**
   - Fillers: filled pauses from the transcript; lexical fillers ("like", "so") classified in context by the LLM.
   - Repetitions and restarts: repeated n-gram rules, plus the LLM for self-corrections.
   - Blocks: pauses classified by position (inside a phrase or at a boundary) using punctuation, syntax and what follows the pause.
4. **Coaching:** the Anthropic API (Claude) with structured output, given the prompt, the timed transcript, the detected events, the metrics, the rubric version, and the previous take when it is a retry.
   It returns the verdict, strength, focus items, dimension levels, outline and reference version defined in [product.md#feedback](product.md#feedback).
   The model is a setting: start with the most capable model for quality and evaluate a faster one for driving latency.
5. **Comparison:** for a retry, focus items and metrics against the previous take.

Prompt generation for impromptu questions also uses Claude, given a short work-context profile that Ryan writes.

## Speech to text

The transcript must be verbatim.
Most engines, Whisper included, silently remove "um", "uh", repetitions and false starts, which would hide exactly what SpeakUp measures.

The engine sits behind one interface with two candidates, chosen by the M0 bake-off on Ryan's own recordings:

- **CrisperWhisper** on the Mac mini: built for verbatim transcription with the most accurate word timestamps measured.
  Free; its weights are licensed for non-commercial use only, which suits personal use and would need revisiting before any product launch.
  On macOS it runs on the PyTorch backend through the GPU (MPS): its 4 to 5 times faster CTranslate2 backend ships Linux wheels only, and there is no MLX port.
- **ElevenLabs Scribe v2** as a cloud API: keeps fillers by default with the best measured cloud accuracy, about $0.22 per hour.
  It sends audio to a third party.

The bake-off also runs two reference engines: AssemblyAI Universal-3.5 Pro with a verbatim prompt, the strongest candidate for Mandarin later, and Apple's on-device `SpeechTranscriber`, which shows what the iPhone could do without a server.
The procedure and decision criteria are in [bakeoff.md](bakeoff.md).

Every engine returns words with start and end times in seconds.
Engines write the same speech differently ("[UM]", "Um,", "th-", "(laughter)"), so analysis normalizes tokens first (`bakeoff/text.py`).

Ruled out: Whisper and its variants (they drop fillers), OpenAI's newer transcription models (no word timestamps), Parakeet and Canary (weak on fillers).
Evidence and alternatives are in [research.md#speech-to-text](research.md#speech-to-text).

## Configuration

Secrets live in ignored files only: the Anthropic API key, any speech-to-text API key, and the server bearer token.
The server reads them from the environment, then from `server/.env`; `server/.env.example` lists the names.
The app keeps the server address and token in the Keychain.

## Data and privacy

Recordings contain Ryan's work content.

- Audio, transcripts and reports are stored on the Mac mini and cached on the iPhone.
- Transcripts, and the prompts that contain work context, are sent to Anthropic for coaching.
- Audio is sent to ElevenLabs only if Scribe wins the bake-off.
- During the bake-off only, the test recordings go to ElevenLabs and, when its key is set, to AssemblyAI.

Any new service that receives audio or transcripts is added to this list in the same change.
