# Speech-to-text bake-off (M0)

The bake-off picks the speech-to-text engine by running every candidate on Ryan's own recordings.
The code is in `server/src/speakup/bakeoff/`; the engines it compares are in `server/src/speakup/stt/`.
Why these engines are the candidates is in [research.md#speech-to-text](research.md#speech-to-text).

## Run it

1. **Record.** Use Voice Memos on the iPhone with **Settings > Apps > Voice Memos > Audio Quality** set to **Lossless**.
   Record 10 to 15 takes of 1 to 5 minutes: stand-up updates and impromptu answers, a few deliberately messy.
   Record at least three in the car with the phone connected to the car, so the car's microphone is tested too.
   Name each file after what it is, such as `standup-1` or `car-impromptu-2`; the name becomes the clip's name in the report.
2. **Copy the recordings** to `data/bakeoff/clips/` at the repository root.
   `data/` is ignored by git because the recordings hold Ryan's voice and work content.
3. **Set up**, once, from `server/`:
   - `cp .env.example .env`, then fill in `ELEVENLABS_API_KEY` and, optionally, `ASSEMBLYAI_API_KEY`.
   - `uv sync --extra crisper` installs everything, including local CrisperWhisper.
   - `swift build -c release --package-path ../tools/apple-transcribe` builds the Apple engine.
   - `uv run speakup-bakeoff engines` shows which engines are ready.
4. **Transcribe** every clip with every ready engine: `uv run speakup-bakeoff transcribe`.
   Transcripts are cached in `data/bakeoff/transcripts/`, so rerunning only does new clips; `--force` redoes them.
   The first CrisperWhisper run downloads its model weights, a few GB.
5. **Correct three or four gold transcripts.**
   `uv run speakup-bakeoff draft-gold` writes drafts to `data/bakeoff/gold/`, starting from Scribe's output (`--engine` picks another).
   Open each draft, listen to the clip, and edit the text until it is exactly what was said, following the rules at the top of the file.
   Then delete its `# DRAFT` line; drafts are not scored.
   Pick clips with plenty of fillers and restarts.
6. **Report:** `uv run speakup-bakeoff report` writes `data/bakeoff/report.md`, and one file per clip in `data/bakeoff/report/` showing what each engine missed.

## How to decide

In order of weight:

1. **Filled pauses found** against the gold transcripts.
   An engine that misses fillers makes the fluency feedback wrong, and nothing downstream can recover them.
2. **Repetitions kept** and **cut-offs kept**: the evidence for blocks and restarts.
3. **Pause edge error**: blocks are judged from pauses of 250 ms or more, so word edges within about 50 to 100 ms are good enough.
4. **Speed**: driving mode aims at spoken feedback within about 20 seconds of a two-minute take, which leaves the engine roughly 10 seconds, so about 12x real time or faster.
5. **Car clips**: if every engine does much worse on them, the app should record with the iPhone microphone instead of the car's.
6. **Privacy and cost**: a local engine keeps audio at home; a cloud engine wins only if it is clearly more accurate.

The decision and its numbers go into [architecture.md#speech-to-text](architecture.md#speech-to-text), and the M0 items in [status.md](status.md) are removed.

## Measurement limits

- Reference pauses come from voice activity detection, which has its own error; small differences between engines are noise.
- Lexical fillers ("like", "so", "you know") are not scored, because deciding whether "like" is a filler needs context.
- Gold drafts start from one engine's output, which can bias the corrector toward it.
- The Apple engine gives one time range per text run; runs are almost always single words.
