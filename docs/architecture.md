# Architecture

Status: planned design.
Only the speech-to-text layer and the M0 bake-off are built; other sections gain code paths as code lands.
The M1 system contract runs from [Domain model](#domain-model) to [Pipeline orchestration](#pipeline-orchestration).

## Code map

| Path | What it is |
| --- | --- |
| `server/` | Python package `speakup`, managed by `uv`; the future analysis server |
| `server/src/speakup/stt/` | Speech-to-text engines behind one interface: `Word`, `Transcript`, `Engine` in `__init__.py`, one module per engine, `registry.py` |
| `server/src/speakup/bakeoff/` | M0 bake-off: alignment (`align.py`), scoring (`metrics.py`), reference pauses (`vad.py`, on the analysis voice-activity track), report and command line |
| `server/src/speakup/text.py` | Token normalization, shared by analysis and the bake-off |
| `server/src/speakup/analysis/` | Analysis: acoustics, event rules, metrics, `Thresholds`, finalization and metric comparison |
| `server/src/speakup/config.py` | Settings and secrets from the environment and `server/.env` |
| `server/tests/` | Unit tests |
| `tools/apple-transcribe/` | Swift command-line tool that runs Apple's `SpeechTranscriber` and prints JSON |
| `server/src/speakup/{coaching,store,pipeline,api}` | M1, planned: see [Module boundaries and ownership](#module-boundaries-and-ownership) |
| `ios/` | M1, planned: the SwiftUI app |
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
  Takes are uploaded as mono 16-bit PCM WAV at the recorded rate; see [the upload endpoint](#put-v1takestake_id).
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
- **Jobs:** each take runs the pipeline as a background job; the app polls the take's status. See [Pipeline orchestration](#pipeline-orchestration).
- **Latency target:** spoken feedback within about 20 seconds of the end of a two-minute take in driving mode.
  M0 measures whether each engine meets it.

### Pipeline stages

Each stage has a narrow interface and writes its output to the take's record, so a stage can be rerun or replaced on its own.

1. **Speech to text:** audio in, verbatim words out, each with start and end time and confidence. See [Speech to text](#speech-to-text).
2. **Acoustics:** voice activity detection (Silero VAD) for silence spans, and Parselmouth (Praat) for pitch and intensity.
   Pauses come from the voice-activity track cross-checked against word gaps, because word gaps alone absorb breaths.
3. **Disfluency detection:**
   - Fillers: filled pauses from the transcript; lexical fillers ("like", "so") marked as candidates with a rules estimate, then judged in context by the LLM during coaching.
   - Repetitions and restarts: repeated n-gram and cut-off rules, plus the LLM for self-corrections, also during coaching.
   - Blocks: pauses classified by position (inside a phrase or at a boundary) using punctuation, syntax and what follows the pause.
4. **Coaching:** the Anthropic API (Claude) with structured output, given the prompt, the timed transcript, the detected events, the metrics, the rubric version, and the previous take when it is a retry.
   It returns the verdict, strength, focus items, dimension levels, outline and reference version defined in [product.md#feedback](product.md#feedback), its rulings on lexical filler candidates, extra transcript annotations, and for a retry its judgment of each previous focus item.
   The model is a setting: start with the most capable model for quality and evaluate a faster one for driving latency.
5. **Comparison:** for a retry, the coaching judgment of the previous focus items plus metric and dimension changes computed against the previous take.
   The judgment comes from the same Claude call as the report, so a retry costs one call and its report and comparison agree.

Stage 1 runs while the take's status is `transcribing`.
Stages 2 and 3 together are **analysis** (`analyzing`) and produce the [Analysis output](#analysis-output).
Stage 4 (`coaching`) produces the [Coaching report](#coaching-report), and stage 5 is composed when the app asks for the [comparison](#comparison).

Prompt generation for impromptu questions also uses Claude, given a short work-context profile that Ryan writes.

## Domain model

This and the following sections up to [Pipeline orchestration](#pipeline-orchestration) are the M1 system contract.
The analysis pipeline, the coaching module, the server API with storage, and the iOS app are built against them in parallel; a change to a shape here changes this doc in the same commit.

### Conventions

- **Ids** are lowercase UUID strings (version 4).
  The app creates sessions, prompts and takes and their ids, so a take recorded without a connection can be uploaded later and every create is an idempotent `PUT`.
  Swift's `UUID().uuidString` is uppercase; the app lowercases it.
- **Timestamps** are RFC 3339 in UTC with milliseconds, such as `2026-11-09T08:15:30.123Z`.
  The server always writes milliseconds and accepts input with or without them.
- **Times inside a take** (`start`, `end`, `*_s`) are seconds from the start of the take's audio, as numbers.
- **JSON keys** are `snake_case`.
  Optional values are present with `null`, never omitted.
- **Forward compatibility:** readers ignore unknown keys and treat an unknown enum value as the most neutral display (for example, an unknown event type is shown as plain text).
  Adding keys or enum values does not change the API version; renaming or removing them does.

### Entities

| Entity | Created by | Holds | Stored in |
| --- | --- | --- | --- |
| Session | App | mode (`home` or `driving`), start and end, nervousness before and after | `sessions` table |
| Prompt | App | kind, text, notes, category, target length, question source | `prompts` table |
| Take | App, by upload | attempt number, recording time, duration, audio hash, processing status | `takes` table; audio under `takes/<take_id>/` |
| Transcript | Server, stage 1 | the engine's `Transcript` (the existing type in `speakup.stt`) | `transcripts` table |
| Analysis | Server, stages 2 and 3 | words, events, metrics, nervousness signs, provenance | `analyses` table, as JSON |
| CoachingReport | Server, stage 4 | verdict, strength, focus, dimension levels, outline, reference version, filler rulings, annotations, retry judgment | `coaching_reports` table, as JSON |
| Comparison | Server, on request | a retry against its previous take | not stored; composed from the two takes |

A session holds prompts in creation order, and a prompt holds takes numbered by `attempt` from 1.
A retry is a new take on the same prompt.
The **previous take** of attempt n is the take of the same prompt with the highest attempt below n whose status is `done`; attempt 1 has none.
The app assigns `attempt` when Ryan keeps a recording; a recording he cancels never gets one.

**Session** fields: `id`, `mode` (`home` or `driving`), `started_at`, `ended_at` (null while open), `nervousness_before` and `nervousness_after` (integer 1 to 5, or null when skipped), `created_at`, `updated_at`.

**Prompt** fields:

| Field | Type | Meaning |
| --- | --- | --- |
| `id` | UUID | |
| `session_id` | UUID | |
| `kind` | `prepared` or `impromptu` | |
| `text` | string | Prepared: a short title Ryan types, such as "Today's stand-up". Impromptu: the question. |
| `notes` | string or null | Prepared only: the points Ryan typed or dictated before recording. Always null for impromptu. |
| `category` | `decision`, `status`, `explain`, `pushback`, `other`, or null | Impromptu question type; null for prepared |
| `target_seconds` | integer | Suggested length; the app shows it and never cuts a take off at it |
| `question_source` | `typed`, `claude`, or `bank` | Who wrote `text`: Ryan, Claude, or the built-in question bank |
| `created_at` | timestamp | |

Impromptu categories map to the drills in [product.md#practice-loop](product.md#practice-loop): `decision` ("Why did you choose X over Y?"), `status` ("Give a status update on a project that is behind"), `explain` ("Explain a concept to a new teammate"), `pushback` ("Push back on a request"), and `other`.

### Take lifecycle

```text
uploaded ──▶ transcribing ──▶ analyzing ──▶ coaching ──▶ done
                  │               │
                  └───────────────┴──────────▶ failed
```

| `status` | Meaning |
| --- | --- |
| `uploaded` | Audio is stored; the take waits for the worker |
| `transcribing` | Converting audio to 16 kHz WAV and running speech to text |
| `analyzing` | Acoustics, disfluency rules and metrics |
| `coaching` | The Claude call is running (skipped at once when coaching is unavailable) |
| `done` | Analysis exists; whether coaching exists is in `coaching_status` |
| `failed` | Transcription or analysis failed; `error` says why; the take can be reprocessed |

A coaching failure never fails the take: analysis alone is a useful report.

| `coaching_status` | Meaning |
| --- | --- |
| `pending` | The take has not reached coaching yet |
| `done` | A coaching report exists |
| `unavailable` | No Anthropic API key was configured when the take reached coaching |
| `failed` | The API or output validation failed after retries |

A failed take carries `error.code`, one of:

| Code | Meaning |
| --- | --- |
| `audio_invalid` | The audio could not be decoded or converted |
| `no_speech` | Fewer than 5 words were transcribed; the app offers a retry instead of a report |
| `stt_failed` | The speech-to-text engine failed after retries |
| `analysis_failed` | Analysis raised an error (a bug; the message is logged) |

## Analysis output

`speakup.analysis.analyze` produces one JSON document per take.
It is the input to coaching and, after [finalization](#finalization), what the report shows as the annotated transcript and metrics.

### Words

`words` is the engine's word list in order; `words[i].i == i`.
Events point into it, so the transcript the app renders and the indexes coaching quotes are the same list.

| Field | Type | Meaning |
| --- | --- | --- |
| `i` | integer | Index in `words` |
| `text` | string | The word as the engine wrote it, with its punctuation, for display |
| `norm` | string | Normalized tokens joined by one space, from `tokens_from_words` (see `speakup/text.py`); empty for non-speech |
| `start`, `end` | number | Seconds |
| `confidence` | number or null | Engine confidence, 0 to 1 |
| `kind` | `word`, `filled_pause`, or `non_speech` | `filled_pause` when `norm` is um, uh or hmm; `non_speech` for sounds such as "(laughter)" |
| `cutoff` | boolean | The word was broken off mid-way ("th-") |

Normalization reuses the bake-off's token rules instead of duplicating them: they live in `speakup/text.py`, which both import.

### Word ranges

Every event and coaching anchor names words with a half-open range `word_start` (inclusive) to `word_end` (exclusive).
An empty range (`word_start == word_end == k`) is a point between words: the gap just before word `k`.
Pause events use empty ranges.

### Events

`events` lists everything the report marks in the transcript, ordered by `start`.
All events share one flat shape, so the app and JSON Schema need a single type.

| Field | Type | Meaning |
| --- | --- | --- |
| `id` | string | Stable within the take: `e0`, `e1`, ... from analysis, `c0`, `c1`, ... from coaching |
| `type` | see below | |
| `start`, `end` | number | Seconds; for a pause, the whole hesitation (see below) |
| `word_start`, `word_end` | integer | Half-open word range |
| `source` | `rules` or `coaching` | Who found it |
| `reason` | string or null | Sub-kind, listed per type below |
| `repair_word` | integer or null | Restart: the first word of the repair. Repetition: the first word of the repeated copy. Otherwise null. |
| `is_filler` | boolean or null | Lexical filler only: whether it is used as a filler. Null for every other type. |
| `filler_resolution` | `rules`, `coaching`, or null | Lexical filler only: who decided `is_filler` |
| `note` | string or null | Coaching events: one plain sentence for the transcript tooltip |

| `type` | Found by | `reason` values | Counts as a problem |
| --- | --- | --- | --- |
| `filled_pause` | rules | null | Yes, as a filler |
| `lexical_filler` | rules (candidate), judged by coaching | null | Only when `is_filler` is true |
| `repetition` | rules | `word`, `phrase` | Yes |
| `restart` | rules, coaching | `cutoff` (a broken-off word), `abandoned_phrase` ("we need to - we should"), `self_correction` (coaching only) | Yes |
| `block` | rules | `inside_phrase`, `before_filler`, `before_restart` | Yes |
| `boundary_pause` | rules | `sentence`, `clause` | No; shown faintly |
| `off_topic` | coaching only | null | Yes |

Lexical filler candidates are "like", "you know", "so", "basically", "kind of", "sort of", "I mean", "actually", "right" and "literally".
Analysis sets `is_filler` from rules (for example, sentence-initial "so" followed by a pause, or "like" not followed by a noun phrase) with `filler_resolution: "rules"`; coaching overrides it in context.

Pauses are silences of at least 250 ms between the first and last word, from the voice-activity track cross-checked against word gaps.
Silences and filled pauses between the same two words are one hesitation: "was [0.6 s] um [0.3 s] the" is one hesitation, not two.
Each hesitation becomes at most one `block` or `boundary_pause` event, which spans from the start of its first silence or filled pause to the end of its last, with an empty word range just before its first word; its filled pauses are still marked on their own.
A hesitation in which a silence is followed by a filled pause is a `before_filler` block, and one right before a restart or repetition is a `before_restart` block, from 250 ms.
At a sentence or clause boundary a hesitation is a `boundary_pause`, unless a silence is followed by a filled pause and the whole hesitation lasts at least 1 second, which makes it a `before_filler` block: getting stuck between ideas.
Inside a phrase a hesitation is an `inside_phrase` block from 500 ms; a shorter one is no event, and no pause metric counts it.
These two values (`Thresholds.block_min_s` and `boundary_filler_block_min_s`) are starting points, to be calibrated on Ryan's takes.
Silence before the first word is the `speech_start_s` metric, not an event; for an impromptu prompt it is thinking time.

### Metrics

Denominators: `word_count` counts words of kind `word` (lexical fillers and cut-off words included; filled pauses and non-speech excluded).
`speaking_s` runs from the first word's start to the last word's end; `voiced_s` is the voice-activity time inside it.
"Quarters" split `speaking_s` into four equal parts.

| Key | Type | Meaning |
| --- | --- | --- |
| `duration_s` | number | Whole recording |
| `speech_start_s` | number | Silence before the first word |
| `speaking_s`, `voiced_s` | number | See above |
| `word_count` | integer | See above |
| `fillers.filled_pauses` | integer | um, uh, hmm |
| `fillers.lexical` | integer | Lexical candidates with `is_filler` true |
| `fillers.lexical_candidates` | integer | All lexical candidates |
| `fillers.per_100_words` | number | (filled pauses + lexical fillers) / `word_count` × 100 |
| `fillers.resolution` | `rules` or `coaching` | Whether coaching has judged the lexical candidates |
| `blocks.count` | integer | Block events, one per hesitation |
| `blocks.per_minute` | number | Per minute of `speaking_s` |
| `blocks.longest_s`, `blocks.total_s` | number | |
| `boundary_pauses.count` | integer | Boundary pause events, one per hesitation |
| `boundary_pauses.median_s` | number or null | |
| `restarts`, `repetitions` | integer | Event counts |
| `pace.wpm_voiced` | number | `word_count` / `voiced_s` × 60; the product's pace metric |
| `pace.wpm_speaking` | number | `word_count` / `speaking_s` × 60 |
| `pace.by_quarter_wpm` | 4 numbers | Voiced-time pace per quarter |
| `pitch` | object or null | Null when there is too little voiced audio to measure |
| `pitch.median_hz` | number | |
| `pitch.variation_st` | number | Standard deviation of pitch in semitones around the median; low means monotone |
| `pitch.range_st` | number | 5th to 95th percentile, in semitones |
| `pitch.by_quarter_median_hz` | 4 numbers | |
| `volume` | object or null | |
| `volume.median_db` | number | Intensity over voiced frames (Praat dB, uncalibrated) |
| `volume.variation_db` | number | Standard deviation |
| `volume.by_quarter_median_db` | 4 numbers | |

Pace, pitch and volume are shown for information and are not graded in v1, as [product.md#metrics](product.md#metrics) says.

### Nervousness signs

`nervousness_signs` lists only the signs present, each `{type, start, end, value, detail}`.
They are shown next to the self-rating and never combined into a score.

| `type` | Present when (thresholds v1, to be calibrated on Ryan's takes) | `value` |
| --- | --- | --- |
| `pace_rise` | Last-quarter pace is at least 15% above first-quarter pace | Percent change |
| `block_cluster` | 3 or more blocks (hesitations) within 15 seconds | Number of blocks |
| `pitch_rise` | Last-quarter median pitch is at least 2 semitones above the first quarter | Semitones |

`detail` is one plain English sentence for display.
Takes under 20 seconds of speaking time get no quarter-based signs.
Thresholds live in one versioned `Thresholds` value in `speakup.analysis`; the version is in `provenance.thresholds_version`.

### Provenance

`provenance` records what produced the document, so results stay comparable when an engine or threshold changes: `pipeline_version` (the `speakup-server` package version), `stt` (`engine` as in the registry, `model`, `version`), `vad` and `prosody` (`engine`, `version`), and `thresholds_version`.

### Finalization

The stored analysis is the rules-only stage output.
`speakup.analysis.finalize(analysis, coaching)` returns the document the report shows: it applies the coaching report's `filler_rulings` to lexical filler events (setting `filler_resolution: "coaching"`), appends its `annotations` as events with `source: "coaching"`, re-sorts events, recomputes `metrics`, and sets `coaching_applied: true`.
With no coaching report it returns the input unchanged, with `coaching_applied: false`.
It is pure, so rerunning coaching only re-finalizes.

### Analysis example

A finalized analysis, with `words` and `events` cut to the first 18 words for length.
The prompt was "Why did we choose Postgres over DynamoDB for the billing service?"

```json
{
  "schema_version": "analysis/1",
  "take_id": "c41a7e02-5b9d-4c66-8e1f-0a7b3d92f5c4",
  "created_at": "2026-11-09T08:17:02.481Z",
  "coaching_applied": true,
  "provenance": {
    "pipeline_version": "0.2.0",
    "stt": {"engine": "crisperwhisper", "model": "nyrahealth/CrisperWhisper", "version": "2.0.4"},
    "vad": {"engine": "silero-vad", "version": "6.2.0"},
    "prosody": {"engine": "parselmouth", "version": "0.4.6"},
    "thresholds_version": "thresholds/1"
  },
  "words": [
    {"i": 0, "text": "So", "norm": "so", "start": 0.84, "end": 1.02, "confidence": 0.98, "kind": "word", "cutoff": false},
    {"i": 1, "text": "um", "norm": "um", "start": 1.1, "end": 1.46, "confidence": 0.91, "kind": "filled_pause", "cutoff": false},
    {"i": 2, "text": "we", "norm": "we", "start": 1.71, "end": 1.8, "confidence": 0.97, "kind": "word", "cutoff": false},
    {"i": 3, "text": "nee-", "norm": "nee", "start": 1.86, "end": 2.02, "confidence": 0.62, "kind": "word", "cutoff": true},
    {"i": 4, "text": "we", "norm": "we", "start": 2.45, "end": 2.55, "confidence": 0.98, "kind": "word", "cutoff": false},
    {"i": 5, "text": "picked", "norm": "picked", "start": 2.6, "end": 2.9, "confidence": 0.99, "kind": "word", "cutoff": false},
    {"i": 6, "text": "Postgres", "norm": "postgres", "start": 2.95, "end": 3.5, "confidence": 0.95, "kind": "word", "cutoff": false},
    {"i": 7, "text": "because,", "norm": "because", "start": 3.55, "end": 3.9, "confidence": 0.99, "kind": "word", "cutoff": false},
    {"i": 8, "text": "like,", "norm": "like", "start": 4.0, "end": 4.2, "confidence": 0.96, "kind": "word", "cutoff": false},
    {"i": 9, "text": "the", "norm": "the", "start": 5.3, "end": 5.4, "confidence": 0.99, "kind": "word", "cutoff": false},
    {"i": 10, "text": "reporting", "norm": "reporting", "start": 5.42, "end": 5.9, "confidence": 0.99, "kind": "word", "cutoff": false},
    {"i": 11, "text": "queries", "norm": "queries", "start": 5.95, "end": 6.4, "confidence": 0.98, "kind": "word", "cutoff": false},
    {"i": 12, "text": "need", "norm": "need", "start": 6.45, "end": 6.65, "confidence": 0.99, "kind": "word", "cutoff": false},
    {"i": 13, "text": "joins.", "norm": "joins", "start": 6.7, "end": 7.1, "confidence": 0.97, "kind": "word", "cutoff": false},
    {"i": 14, "text": "Uh", "norm": "uh", "start": 7.8, "end": 8.1, "confidence": 0.88, "kind": "filled_pause", "cutoff": false},
    {"i": 15, "text": "the", "norm": "the", "start": 8.3, "end": 8.4, "confidence": 0.97, "kind": "word", "cutoff": false},
    {"i": 16, "text": "the", "norm": "the", "start": 8.42, "end": 8.5, "confidence": 0.95, "kind": "word", "cutoff": false},
    {"i": 17, "text": "team", "norm": "team", "start": 8.55, "end": 8.8, "confidence": 0.99, "kind": "word", "cutoff": false}
  ],
  "events": [
    {"id": "e0", "type": "filled_pause", "start": 1.1, "end": 1.46, "word_start": 1, "word_end": 2, "source": "rules", "reason": null, "repair_word": null, "is_filler": null, "filler_resolution": null, "note": null},
    {"id": "e1", "type": "restart", "start": 1.71, "end": 2.02, "word_start": 2, "word_end": 4, "source": "rules", "reason": "cutoff", "repair_word": 4, "is_filler": null, "filler_resolution": null, "note": null},
    {"id": "e2", "type": "lexical_filler", "start": 4.0, "end": 4.2, "word_start": 8, "word_end": 9, "source": "rules", "reason": null, "repair_word": null, "is_filler": true, "filler_resolution": "coaching", "note": null},
    {"id": "e3", "type": "block", "start": 4.2, "end": 5.3, "word_start": 9, "word_end": 9, "source": "rules", "reason": "inside_phrase", "repair_word": null, "is_filler": null, "filler_resolution": null, "note": null},
    {"id": "e4", "type": "block", "start": 7.1, "end": 8.1, "word_start": 14, "word_end": 14, "source": "rules", "reason": "before_filler", "repair_word": null, "is_filler": null, "filler_resolution": null, "note": null},
    {"id": "e5", "type": "filled_pause", "start": 7.8, "end": 8.1, "word_start": 14, "word_end": 15, "source": "rules", "reason": null, "repair_word": null, "is_filler": null, "filler_resolution": null, "note": null},
    {"id": "e6", "type": "repetition", "start": 8.3, "end": 8.5, "word_start": 15, "word_end": 17, "source": "rules", "reason": "word", "repair_word": 16, "is_filler": null, "filler_resolution": null, "note": null},
    {"id": "c0", "type": "off_topic", "start": 31.2, "end": 52.6, "word_start": 74, "word_end": 121, "source": "coaching", "reason": null, "repair_word": null, "is_filler": null, "filler_resolution": null, "note": "The story about the old team's DynamoDB migration does not answer why we chose Postgres."}
  ],
  "metrics": {
    "duration_s": 96.4,
    "speech_start_s": 0.84,
    "speaking_s": 94.1,
    "voiced_s": 71.3,
    "word_count": 214,
    "fillers": {"filled_pauses": 5, "lexical": 3, "lexical_candidates": 7, "per_100_words": 3.74, "resolution": "coaching"},
    "blocks": {"count": 4, "per_minute": 2.55, "longest_s": 1.1, "total_s": 3.6},
    "boundary_pauses": {"count": 21, "median_s": 0.55},
    "restarts": 2,
    "repetitions": 3,
    "pace": {"wpm_voiced": 180.1, "wpm_speaking": 136.5, "by_quarter_wpm": [166.0, 174.2, 181.5, 196.8]},
    "pitch": {"median_hz": 121.4, "variation_st": 2.3, "range_st": 9.8, "by_quarter_median_hz": [118.2, 120.5, 122.0, 125.9]},
    "volume": {"median_db": 61.2, "variation_db": 4.1, "by_quarter_median_db": [60.8, 61.5, 61.0, 61.9]}
  },
  "nervousness_signs": [
    {"type": "pace_rise", "start": 71.4, "end": 94.9, "value": 18.6, "detail": "Pace rose 19% from the first quarter to the last (166 to 197 words per minute)."}
  ]
}
```

## Coaching report

`speakup.coaching.coach_take` calls Claude with [structured outputs](https://platform.claude.com/docs/en/build-with-claude/structured-outputs): the response format is a JSON Schema generated from the coaching module's Pydantic model.
What Claude returns is the **coaching output**; the server adds metadata and anchor times and stores the **coaching report**.

### Schema rules

Structured outputs accept objects with `additionalProperties: false`, `enum`, `anyOf` and `$ref`, and reject numeric bounds, string lengths and complex array constraints.
So the shape follows these rules:

- Every object lists all its keys as required; a nullable value is `anyOf: [<type>, null]`.
- The six dimensions are an object with six fixed keys, not an array, so the schema itself guarantees all six.
- Counts that the schema cannot express (1 or 2 focus items, 1 to 3 evidence anchors per focus item, focus outcomes covering each previous focus item) are checked after parsing; the Python SDK's `messages.parse` strips the bounds from the schema it sends and validates them locally.
- Every anchor is checked against the transcript: indexes in range, and the quote matches those words after normalization.
  A wrong range is repaired by searching for the quote; if any check still fails, the module re-asks once with the errors, and then reports `coaching_status: "failed"`.
- All text is plain English with no Markdown, written so it can be read aloud, because driving mode speaks the verdict, strength, first focus item and reference version.

Claude sees the transcript as indexed words (`[12]need [13]joins.`), which is how it can return word ranges.

### Coaching output (what Claude returns)

| Field | Type | Meaning |
| --- | --- | --- |
| `verdict` | string | One or two sentences on how the answer landed |
| `strength` | object | `dimension` (one of the six), `point` (what worked), `anchor` |
| `focus` | array of 1 or 2 | Most important first; each `dimension`, `title` (short imperative), `problem`, `evidence` (1 to 3 anchors), `instruction` (what to do in the next take) |
| `dimensions` | object | Keys `answer_first`, `layering`, `focus`, `concision`, `fluency`, `close`; each `{level, evidence}` with `level` one of `strong`, `okay`, `needs_work` |
| `outline` | object | `main_point` (string), `main_point_first` (boolean), `points` (array of `{summary, role, word_start, word_end}`, `role` one of `main`, `support`, `example`, `aside`, `close`) |
| `reference_version` | object | `text` (Ryan's content restructured answer-first and in layers; paragraphs separated by a blank line) and `structure` (one line naming the shape, such as "Decision, two numbered reasons, the trade-off") |
| `filler_rulings` | array | `{event_id, is_filler}` for every `lexical_filler` event in the input |
| `annotations` | array | Extra transcript marks: `{type, word_start, word_end, note}`, `type` one of `off_topic`, `restart` (a self-correction the rules missed) |
| `comparison` | object or null | Null unless the take is a retry whose previous take has a coaching report. `summary` (one or two sentences) and `focus_outcomes`: one per previous focus item, `{previous_focus_index, outcome, evidence, anchor}`, `outcome` one of `improved`, `partly_improved`, `not_improved`, `not_applicable`, `anchor` nullable |

An **anchor** is `{quote, word_start, word_end}`: the exact words quoted, and their half-open range.
The six dimensions are the ones in [product.md#grading](product.md#grading).
The fluency level is judged from the metrics and events Claude is given, so it agrees with the numbers on screen.

### Coaching report (stored and served)

The coaching output plus `schema_version` (`coaching/1`), `take_id`, `created_at`, `model` (the Claude model id), `rubric_version` (such as `rubric/1`), and `prompt_version` (such as `coach-prompt/1`).
Every anchor gains `start` and `end` in seconds, from its words, so the app can play the quoted audio.
An empty-range anchor would have no audio, so anchors always cover at least one word.

### Coaching example

The report for the take in the [analysis example](#analysis-example), attempt 1:

```json
{
  "schema_version": "coaching/1",
  "take_id": "c41a7e02-5b9d-4c66-8e1f-0a7b3d92f5c4",
  "created_at": "2026-11-09T08:17:24.902Z",
  "model": "claude-opus-5-5",
  "rubric_version": "rubric/1",
  "prompt_version": "coach-prompt/1",
  "verdict": "You named the decision in the first sentence, which is right, but your reasons came out as one long run and the answer trailed off at the end. Clear enough to follow, not yet crisp.",
  "strength": {
    "dimension": "answer_first",
    "point": "You said what was chosen before explaining anything, so the listener knew where you were going.",
    "anchor": {"quote": "we picked Postgres because", "word_start": 4, "word_end": 8, "start": 2.45, "end": 3.9}
  },
  "focus": [
    {
      "dimension": "layering",
      "title": "Number your reasons",
      "problem": "Three reasons came as one unbroken list, so it was hard to tell which one mattered most.",
      "evidence": [
        {"quote": "the reporting queries need joins", "word_start": 9, "word_end": 14, "start": 5.3, "end": 7.1}
      ],
      "instruction": "Say how many reasons there are, then give them in order of weight: \"Two reasons. First, reporting needs joins. Second, ...\""
    },
    {
      "dimension": "fluency",
      "title": "Stop silently, not mid-phrase",
      "problem": "You froze for over a second in the middle of your main reason, right after a filler.",
      "evidence": [
        {"quote": "because, like, the", "word_start": 7, "word_end": 10, "start": 3.55, "end": 5.4}
      ],
      "instruction": "When you need a moment, finish the clause, pause in silence, and start the reason fresh."
    }
  ],
  "dimensions": {
    "answer_first": {"level": "strong", "evidence": "The decision is in the first sentence."},
    "layering": {"level": "needs_work", "evidence": "No signposts; three reasons run together."},
    "focus": {"level": "okay", "evidence": "One long aside about the old team's migration did not serve the question."},
    "concision": {"level": "okay", "evidence": "The joins point was made twice in slightly different words."},
    "fluency": {"level": "okay", "evidence": "3.7 fillers per 100 words is in the normal range; one long block before the main reason."},
    "close": {"level": "needs_work", "evidence": "The answer ended with \"so yeah, that's kind of it\"."}
  },
  "outline": {
    "main_point": "We chose Postgres because billing reports need joins and transactions.",
    "main_point_first": true,
    "points": [
      {"summary": "Chose Postgres over DynamoDB", "role": "main", "word_start": 0, "word_end": 7},
      {"summary": "Reporting queries need joins", "role": "support", "word_start": 7, "word_end": 14},
      {"summary": "The team knows Postgres better", "role": "support", "word_start": 14, "word_end": 41},
      {"summary": "Story about the old team's DynamoDB migration", "role": "aside", "word_start": 74, "word_end": 121},
      {"summary": "Trails off with \"so yeah\"", "role": "close", "word_start": 203, "word_end": 214}
    ]
  },
  "reference_version": {
    "text": "We chose Postgres for billing. Two reasons.\n\nFirst, billing reports join invoices, customers and plans, and joins are painful in DynamoDB. Second, an invoice and its ledger entries must change together, so we need transactions.\n\nThe cost is that we scale writes ourselves, which is fine at our volume for the next two years.",
    "structure": "Decision, two numbered reasons, the trade-off."
  },
  "filler_rulings": [
    {"event_id": "e2", "is_filler": true}
  ],
  "annotations": [
    {"type": "off_topic", "word_start": 74, "word_end": 121, "note": "The story about the old team's DynamoDB migration does not answer why we chose Postgres."}
  ],
  "comparison": null
}
```

For attempt 2 of the same prompt, `comparison` is filled:

```json
{
  "summary": "The reasons are now numbered and the long block is gone; the ending still trails off.",
  "focus_outcomes": [
    {
      "previous_focus_index": 0,
      "outcome": "improved",
      "evidence": "You announced two reasons and numbered them.",
      "anchor": {"quote": "Two reasons. First,", "word_start": 6, "word_end": 9, "start": 2.1, "end": 3.0}
    },
    {
      "previous_focus_index": 1,
      "outcome": "partly_improved",
      "evidence": "No block before the main reason this time, but two \"like\" fillers came back in the second reason.",
      "anchor": null
    }
  ]
}
```

### Comparison

`GET /v1/takes/{take_id}/comparison` composes a retry's comparison from the take, its previous take, their finalized analyses and their coaching reports.
It is not stored, so it always reflects the current state of both takes.

| Field | Type | Meaning |
| --- | --- | --- |
| `take_id`, `previous_take_id` | UUID | |
| `attempt`, `previous_attempt` | integer | |
| `coaching_status` | as on the take | Of this take |
| `summary` | string or null | From this take's coaching `comparison`; null without it |
| `focus_outcomes` | array | One per previous focus item: `title` and `dimension` from the previous report, `outcome`, `evidence`, `anchor` from this report. Empty when either take has no coaching. |
| `dimension_changes` | array | Six items `{dimension, before, after, change}`, `change` one of `better`, `same`, `worse`. Empty when either take has no coaching. |
| `metric_changes` | array | From `speakup.analysis.compare_metrics`: `{metric, label, unit, before, after, change}`, `change` one of `better`, `same`, `worse`, `info` |

`metric_changes` always has these metrics in this order: `fillers_per_100_words`, `blocks`, `restarts`, `repetitions` (graded: lower is better), then `wpm_voiced`, `duration_s`, `pitch_variation_st`, `volume_variation_db` (`info`, not graded).
A graded metric is `same` when counts are equal or a rate moved less than 10%.
A metric that is null on either side has `change: "info"` and the null value.

```json
{
  "take_id": "e98b1f37-2a4c-4d1e-9f60-6b5c8a0d3e21",
  "previous_take_id": "c41a7e02-5b9d-4c66-8e1f-0a7b3d92f5c4",
  "attempt": 2,
  "previous_attempt": 1,
  "coaching_status": "done",
  "summary": "The reasons are now numbered and the long block is gone; the ending still trails off.",
  "focus_outcomes": [
    {"title": "Number your reasons", "dimension": "layering", "outcome": "improved", "evidence": "You announced two reasons and numbered them.", "anchor": {"quote": "Two reasons. First,", "word_start": 6, "word_end": 9, "start": 2.1, "end": 3.0}},
    {"title": "Stop silently, not mid-phrase", "dimension": "fluency", "outcome": "partly_improved", "evidence": "No block before the main reason this time, but two \"like\" fillers came back in the second reason.", "anchor": null}
  ],
  "dimension_changes": [
    {"dimension": "answer_first", "before": "strong", "after": "strong", "change": "same"},
    {"dimension": "layering", "before": "needs_work", "after": "strong", "change": "better"},
    {"dimension": "focus", "before": "okay", "after": "strong", "change": "better"},
    {"dimension": "concision", "before": "okay", "after": "okay", "change": "same"},
    {"dimension": "fluency", "before": "okay", "after": "okay", "change": "same"},
    {"dimension": "close", "before": "needs_work", "after": "needs_work", "change": "same"}
  ],
  "metric_changes": [
    {"metric": "fillers_per_100_words", "label": "Fillers per 100 words", "unit": "per 100 words", "before": 3.74, "after": 2.9, "change": "better"},
    {"metric": "blocks", "label": "Blocks", "unit": "count", "before": 4, "after": 1, "change": "better"},
    {"metric": "restarts", "label": "Restarts", "unit": "count", "before": 2, "after": 2, "change": "same"},
    {"metric": "repetitions", "label": "Repetitions", "unit": "count", "before": 3, "after": 4, "change": "worse"},
    {"metric": "wpm_voiced", "label": "Pace", "unit": "words per minute", "before": 180.1, "after": 171.4, "change": "info"},
    {"metric": "duration_s", "label": "Length", "unit": "seconds", "before": 96.4, "after": 78.2, "change": "info"},
    {"metric": "pitch_variation_st", "label": "Pitch variation", "unit": "semitones", "before": 2.3, "after": 2.6, "change": "info"},
    {"metric": "volume_variation_db", "label": "Volume variation", "unit": "dB", "before": 4.1, "after": 4.0, "change": "info"}
  ]
}
```

### Impromptu questions

`speakup.coaching.generate_questions` asks Claude for questions, with structured output `{"questions": [{"text", "category", "target_seconds"}]}`, given Ryan's work-context profile, the requested category, and the questions to avoid.
Without an API key, or if the call fails, it draws from a built-in bank of about 40 general work questions across the five categories, so impromptu practice never depends on Claude.
The profile is a plain-text file, `profile.md` in the server's data directory, that Ryan edits by hand; the app does not edit it in M1.

## Server API

FastAPI, versioned under `/v1`, JSON in and out except the take upload (multipart) and the audio download.

### Transport and auth

- The server listens on `127.0.0.1:8765` and is published to the tailnet only, over HTTPS with a valid certificate, by `tailscale serve`.
  The app's server address is then `https://<machine>.<tailnet>.ts.net`, and iOS needs no App Transport Security exception.
- Every request, including `/v1/health`, sends `Authorization: Bearer <token>`.
  The token is `SPEAKUP_API_TOKEN` in `server/.env` (32 random bytes, URL-safe base64), compared in constant time.
  A missing or wrong token gets `401 unauthorized` and nothing else.

### Errors

Every non-2xx response has this body, including FastAPI's own validation errors, which the API maps to it:

```json
{"error": {"code": "not_found", "message": "No take with id e98b1f37-2a4c-4d1e-9f60-6b5c8a0d3e21.", "details": null}}
```

| HTTP | `code` | When |
| --- | --- | --- |
| 400 | `bad_request` | Malformed body or multipart |
| 401 | `unauthorized` | Missing or wrong token |
| 404 | `not_found` | Unknown id in the path, or an unknown parent id in the body (`details.field` names it) |
| 404 | `no_previous_take` | Comparison asked for attempt 1, or no earlier take is done |
| 409 | `conflict` | A create reused an id with different content |
| 409 | `not_ready` | Report or comparison asked for before analysis exists (`details.status` is the take's status) |
| 409 | `invalid_state` | Reprocess asked for while the take is still processing |
| 413 | `payload_too_large` | Audio over 100 MB |
| 415 | `unsupported_media_type` | Audio that is not WAV |
| 422 | `validation_failed` | A field fails validation; `details.errors` lists `{field, message}` |
| 500 | `internal` | A bug; the message is generic and the log has the trace |

### Why the app polls

The app learns a take finished by polling `GET /v1/takes/{take_id}` every 1.5 seconds while the processing screen is visible, and by refreshing on foreground.
One user, one take at a time, a status read that is one SQLite row, and a private network make polling cheap and simple.
Server-sent events or WebSockets would add reconnect handling and still stop when iOS suspends the app; push notifications would need APNs credentials on the Mac mini.
Revisit when driving mode needs feedback while the phone is locked (M2).

### Endpoints

| Method and path | Purpose |
| --- | --- |
| `GET /v1/health` | Check the address and token; show server and coaching info |
| `PUT /v1/sessions/{session_id}` | Create a session |
| `PATCH /v1/sessions/{session_id}` | End a session; record nervousness self-ratings |
| `GET /v1/sessions` | History: sessions, newest first |
| `GET /v1/sessions/{session_id}` | One session with its prompts and takes |
| `POST /v1/questions` | Generate impromptu questions |
| `PUT /v1/prompts/{prompt_id}` | Create a prompt |
| `GET /v1/prompts/{prompt_id}` | One prompt with its takes |
| `PUT /v1/takes/{take_id}` | Upload a take |
| `GET /v1/takes/{take_id}` | Take status, polled |
| `GET /v1/takes/{take_id}/report` | The full report |
| `GET /v1/takes/{take_id}/comparison` | A retry's comparison with its previous take |
| `GET /v1/takes/{take_id}/audio` | The uploaded audio |
| `POST /v1/takes/{take_id}/reprocess` | Rerun a take from a stage |

#### `GET /v1/health`

Response `200`:

```json
{
  "status": "ok",
  "api_version": "v1",
  "server_version": "0.2.0",
  "stt_engine": "crisperwhisper",
  "coaching": {"available": true, "model": "claude-opus-5-5", "rubric_version": "rubric/1", "prompt_version": "coach-prompt/1"},
  "queue_length": 0
}
```

#### `PUT /v1/sessions/{session_id}`

Request:

```json
{"mode": "home", "started_at": "2026-11-09T08:12:03.115Z", "nervousness_before": 3}
```

Response `201` when created, `200` when a session with this id and the same `mode` and `started_at` already exists (a repeated upload; other fields are ignored, and `PATCH` changes them), `409 conflict` otherwise.
The body is the **Session** resource:

```json
{
  "id": "0b6f3c1e-8f5a-4f3e-9a51-2d1c7e4b9a10",
  "mode": "home",
  "started_at": "2026-11-09T08:12:03.115Z",
  "ended_at": null,
  "nervousness_before": 3,
  "nervousness_after": null,
  "created_at": "2026-11-09T08:12:03.402Z",
  "updated_at": "2026-11-09T08:12:03.402Z"
}
```

#### `PATCH /v1/sessions/{session_id}`

This is the nervousness self-rating endpoint and the way a session ends.
Every key is optional; a key that is present is set, and `null` clears a rating.
`ended_at` cannot be cleared once set.

```json
{"ended_at": "2026-11-09T08:41:50.020Z", "nervousness_after": 2}
```

Response `200`: the Session resource.

#### `GET /v1/sessions?before=<timestamp>&limit=<n>`

Sessions with `started_at` before `before` (default: now), newest first; `limit` defaults to 20, at most 100.
Response `200`:

```json
{
  "sessions": [
    {
      "id": "0b6f3c1e-8f5a-4f3e-9a51-2d1c7e4b9a10",
      "mode": "home",
      "started_at": "2026-11-09T08:12:03.115Z",
      "ended_at": "2026-11-09T08:41:50.020Z",
      "nervousness_before": 3,
      "nervousness_after": 2,
      "created_at": "2026-11-09T08:12:03.402Z",
      "updated_at": "2026-11-09T08:41:50.311Z",
      "prompts": [
        {"id": "7d2e9a44-1c3b-4e8f-b6a2-93f0c5d1e7a8", "kind": "impromptu", "text": "Why did we choose Postgres over DynamoDB for the billing service?", "take_count": 2}
      ],
      "take_count": 2
    }
  ],
  "next_before": null
}
```

`next_before` is the `started_at` of the last session returned when more exist, else null.

#### `GET /v1/sessions/{session_id}`

Response `200`: the Session resource plus `prompts`, each a Prompt resource with `takes` (Take resources, by attempt):

```json
{
  "id": "0b6f3c1e-8f5a-4f3e-9a51-2d1c7e4b9a10",
  "mode": "home",
  "started_at": "2026-11-09T08:12:03.115Z",
  "ended_at": "2026-11-09T08:41:50.020Z",
  "nervousness_before": 3,
  "nervousness_after": 2,
  "created_at": "2026-11-09T08:12:03.402Z",
  "updated_at": "2026-11-09T08:41:50.311Z",
  "prompts": [
    {
      "id": "7d2e9a44-1c3b-4e8f-b6a2-93f0c5d1e7a8",
      "session_id": "0b6f3c1e-8f5a-4f3e-9a51-2d1c7e4b9a10",
      "kind": "impromptu",
      "text": "Why did we choose Postgres over DynamoDB for the billing service?",
      "notes": null,
      "category": "decision",
      "target_seconds": 90,
      "question_source": "claude",
      "created_at": "2026-11-09T08:12:40.880Z",
      "takes": []
    }
  ]
}
```

`takes` holds Take resources as in the upload response below; it is empty here only to keep the example short.

#### `POST /v1/questions`

Request (`category` may be null for any; `count` is 1 to 10, default 3; `exclude` holds question texts to avoid, and the server also avoids the last 50 impromptu prompts it stored):

```json
{"count": 3, "category": "decision", "exclude": ["Why did we choose Postgres over DynamoDB for the billing service?"]}
```

Response `200` (`source` is `claude` or `bank`):

```json
{
  "source": "claude",
  "questions": [
    {"text": "Your manager asks why the search rewrite slipped two weeks. Explain what happened and what you are doing about it.", "category": "status", "target_seconds": 90},
    {"text": "Why did you split the notifications service out of the monolith instead of fixing it in place?", "category": "decision", "target_seconds": 90},
    {"text": "A product manager wants a feature by Friday that you think needs two weeks. Push back.", "category": "pushback", "target_seconds": 60}
  ]
}
```

Questions are not stored until the app creates a prompt from one.

#### `PUT /v1/prompts/{prompt_id}`

Request:

```json
{
  "session_id": "0b6f3c1e-8f5a-4f3e-9a51-2d1c7e4b9a10",
  "kind": "impromptu",
  "text": "Why did we choose Postgres over DynamoDB for the billing service?",
  "notes": null,
  "category": "decision",
  "target_seconds": 90,
  "question_source": "claude"
}
```

A prepared prompt looks like `{"kind": "prepared", "text": "Today's stand-up", "notes": "Shipped the invoice export. Blocked on the tax API keys. Next: retry logic.", "category": null, "target_seconds": 120, "question_source": "typed", ...}`.
Validation: `notes` and `category` must be null for the other kind; `target_seconds` is 15 to 900.
Response `201` or `200` (identical repeat) or `409`: the **Prompt** resource, the request plus `id` and `created_at`.

#### `GET /v1/prompts/{prompt_id}`

Response `200`: the Prompt resource plus `takes`, Take resources by attempt.

#### `PUT /v1/takes/{take_id}`

`multipart/form-data` with two parts:

- `metadata`, `application/json`:

  ```json
  {
    "prompt_id": "7d2e9a44-1c3b-4e8f-b6a2-93f0c5d1e7a8",
    "attempt": 2,
    "recorded_at": "2026-11-09T08:19:47.530Z",
    "duration_s": 78.2,
    "audio_sha256": "9f2c4e0b7a1d3c5e8f6a2b4d0c9e7f1a3b5d7c9e1f2a4b6c8d0e2f4a6b8c0d2e",
    "mic_route": "built_in"
  }
  ```

- `audio`, `audio/wav`: mono 16-bit PCM WAV at 16 to 48 kHz, as recorded.

`recorded_at` is when recording started.
`mic_route` is the iOS input port type (`built_in`, `bluetooth_hfp`, `car_audio`, `headset`, `usb`, `other`); it lets M0's car microphone question be answered from real takes.
The server writes the audio to a temporary file, checks the hash, then moves it into place and inserts the take in one step, so a take never exists without its audio.

Response `201` when created, `200` when this id already exists with the same `audio_sha256` (a retried upload), `409 conflict` when the id exists with a different hash or `(prompt_id, attempt)` is taken.
The body is the **Take** resource:

```json
{
  "id": "e98b1f37-2a4c-4d1e-9f60-6b5c8a0d3e21",
  "prompt_id": "7d2e9a44-1c3b-4e8f-b6a2-93f0c5d1e7a8",
  "session_id": "0b6f3c1e-8f5a-4f3e-9a51-2d1c7e4b9a10",
  "attempt": 2,
  "recorded_at": "2026-11-09T08:19:47.530Z",
  "duration_s": 78.2,
  "mic_route": "built_in",
  "status": "uploaded",
  "status_changed_at": "2026-11-09T08:21:06.004Z",
  "coaching_status": "pending",
  "previous_take_id": "c41a7e02-5b9d-4c66-8e1f-0a7b3d92f5c4",
  "error": null,
  "summary": null,
  "created_at": "2026-11-09T08:21:06.004Z",
  "updated_at": "2026-11-09T08:21:06.004Z"
}
```

`previous_take_id` is the previous take as defined in [Entities](#entities), resolved when coaching starts; before then it is the take with attempt n - 1, or null.

#### `GET /v1/takes/{take_id}`

Response `200`: the Take resource.
Once the take is `done`, `summary` is filled from the finalized analysis and the coaching report, for lists and history:

```json
{
  "id": "e98b1f37-2a4c-4d1e-9f60-6b5c8a0d3e21",
  "prompt_id": "7d2e9a44-1c3b-4e8f-b6a2-93f0c5d1e7a8",
  "session_id": "0b6f3c1e-8f5a-4f3e-9a51-2d1c7e4b9a10",
  "attempt": 2,
  "recorded_at": "2026-11-09T08:19:47.530Z",
  "duration_s": 78.2,
  "mic_route": "built_in",
  "status": "done",
  "status_changed_at": "2026-11-09T08:21:41.712Z",
  "coaching_status": "done",
  "previous_take_id": "c41a7e02-5b9d-4c66-8e1f-0a7b3d92f5c4",
  "error": null,
  "summary": {
    "verdict": "Much clearer: the decision comes first and the reasons are numbered. The ending still fades out.",
    "focus_titles": ["Close on purpose"],
    "fillers_per_100_words": 2.9,
    "blocks": 1,
    "restarts": 2,
    "wpm_voiced": 171.4
  },
  "created_at": "2026-11-09T08:21:06.004Z",
  "updated_at": "2026-11-09T08:21:41.712Z"
}
```

`summary.verdict` and `summary.focus_titles` are null and empty without coaching.
A failed take has `"status": "failed"` and `"error": {"code": "no_speech", "message": "Fewer than 5 words were transcribed."}`.

#### `GET /v1/takes/{take_id}/report`

Available once analysis exists (status `coaching` or `done`); `409 not_ready` before, with `details.status`.
Response `200`:

```json
{
  "take": {"id": "c41a7e02-5b9d-4c66-8e1f-0a7b3d92f5c4", "attempt": 1, "status": "done", "coaching_status": "done"},
  "prompt": {"id": "7d2e9a44-1c3b-4e8f-b6a2-93f0c5d1e7a8", "kind": "impromptu", "text": "Why did we choose Postgres over DynamoDB for the billing service?"},
  "analysis": {"schema_version": "analysis/1"},
  "coaching": {"schema_version": "coaching/1"},
  "has_comparison": false
}
```

In the real response, `take` is the full Take resource, `prompt` the full Prompt resource (without `takes`), `analysis` the full **finalized** Analysis document exactly as in the [analysis example](#analysis-example), and `coaching` the full Coaching report exactly as in the [coaching example](#coaching-example), or null when `coaching_status` is not `done`.
`has_comparison` is true when the take has a previous take.

#### `GET /v1/takes/{take_id}/comparison`

Response `200`: the Comparison in [Comparison](#comparison).
`404 no_previous_take` for attempt 1 or when no earlier take of the prompt is done; `409 not_ready` until this take is `done`.

#### `GET /v1/takes/{take_id}/audio`

Response `200`, `audio/wav`: the original upload.
The app plays its own copy when it has one and otherwise downloads the whole file (a few megabytes) with the bearer header, then plays it locally.

#### `POST /v1/takes/{take_id}/reprocess`

Request:

```json
{"from_stage": "coaching"}
```

`from_stage` is `transcribing`, `analyzing` or `coaching`.
Allowed when the take is `done` or `failed`; `409 invalid_state` otherwise.
Rerunning a stage reruns every later stage; earlier outputs are reused.
The app uses `coaching` for "Get coaching" after an API key is added, and `transcribing` to retry a failed take.
Response `202`: the Take resource, with status set to `from_stage` and `coaching_status` back to `pending`.

## Storage

All server state lives under `SPEAKUP_DATA_DIR`, default `data/server/` in the repository, which git ignores:

```text
data/server/
  speakup.db               SQLite database, WAL mode, foreign keys on
  profile.md               Ryan's work-context profile for impromptu questions
  takes/<take_id>/
    original.wav           the upload, unchanged
    audio16k.wav           16 kHz mono 16-bit, made by speakup.audio.to_wav16k for every engine
```

Takes are stored flat by id, not under their session, so a take's files never move.
JSON documents (transcripts, analyses, coaching reports) live in SQLite, not in files, so one backup of the directory is complete and consistent.

```sql
CREATE TABLE schema_migrations (
  version INTEGER PRIMARY KEY,
  applied_at TEXT NOT NULL
);

CREATE TABLE sessions (
  id TEXT PRIMARY KEY,
  mode TEXT NOT NULL CHECK (mode IN ('home', 'driving')),
  started_at TEXT NOT NULL,
  ended_at TEXT,
  nervousness_before INTEGER CHECK (nervousness_before BETWEEN 1 AND 5),
  nervousness_after INTEGER CHECK (nervousness_after BETWEEN 1 AND 5),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX sessions_started ON sessions (started_at);

CREATE TABLE prompts (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES sessions (id),
  kind TEXT NOT NULL CHECK (kind IN ('prepared', 'impromptu')),
  text TEXT NOT NULL,
  notes TEXT,
  category TEXT,
  target_seconds INTEGER NOT NULL,
  question_source TEXT NOT NULL CHECK (question_source IN ('typed', 'claude', 'bank')),
  created_at TEXT NOT NULL
);
CREATE INDEX prompts_session ON prompts (session_id, created_at);

CREATE TABLE takes (
  id TEXT PRIMARY KEY,
  prompt_id TEXT NOT NULL REFERENCES prompts (id),
  attempt INTEGER NOT NULL,
  recorded_at TEXT NOT NULL,
  duration_s REAL NOT NULL,
  mic_route TEXT,
  audio_sha256 TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('uploaded', 'transcribing', 'analyzing', 'coaching', 'done', 'failed')),
  status_changed_at TEXT NOT NULL,
  coaching_status TEXT NOT NULL CHECK (coaching_status IN ('pending', 'done', 'unavailable', 'failed')),
  previous_take_id TEXT REFERENCES takes (id),
  error_code TEXT,
  error_message TEXT,
  stage_failures INTEGER NOT NULL DEFAULT 0,
  transcript_id TEXT REFERENCES transcripts (id),
  analysis_id TEXT REFERENCES analyses (id),
  coaching_id TEXT REFERENCES coaching_reports (id),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (prompt_id, attempt)
);
CREATE INDEX takes_queue ON takes (status, recorded_at);

-- Stage outputs keep every run; takes.*_id points at the current one.
CREATE TABLE transcripts (
  id TEXT PRIMARY KEY,
  take_id TEXT NOT NULL REFERENCES takes (id),
  engine TEXT NOT NULL,
  created_at TEXT NOT NULL,
  json TEXT NOT NULL            -- speakup.stt.Transcript as saved by Transcript.save
);

CREATE TABLE analyses (
  id TEXT PRIMARY KEY,
  take_id TEXT NOT NULL REFERENCES takes (id),
  transcript_id TEXT NOT NULL REFERENCES transcripts (id),
  schema_version TEXT NOT NULL,
  created_at TEXT NOT NULL,
  stage_json TEXT NOT NULL,     -- analyze() output, rules only
  final_json TEXT NOT NULL      -- finalize(stage, coaching); rewritten when coaching changes
);

CREATE TABLE coaching_reports (
  id TEXT PRIMARY KEY,
  take_id TEXT NOT NULL REFERENCES takes (id),
  analysis_id TEXT NOT NULL REFERENCES analyses (id),
  model TEXT NOT NULL,
  rubric_version TEXT NOT NULL,
  prompt_version TEXT NOT NULL,
  created_at TEXT NOT NULL,
  json TEXT NOT NULL,           -- the coaching report
  usage_json TEXT               -- API token usage, for cost tracking
);
```

Keeping every stage run makes it possible to compare a new engine, threshold set or rubric on old takes without losing the old result.
Server-generated ids (transcripts, analyses, coaching reports) are UUIDs too; they never appear in the API.
Schema changes are numbered migrations applied at startup.

## Module boundaries and ownership

Each M1 implementer owns one area and builds against the others through the shapes above and the signatures below, using fakes until the real modules land.
Across module boundaries, analysis and coaching documents travel as plain JSON-compatible dicts in exactly the documented shapes; inside its own package each owner may use Pydantic models (recommended: they validate output and generate the coaching JSON Schema).
The JSON examples in this doc are the canonical fixtures; copy them into tests rather than inventing new ones.

| Package | Owner | Owns |
| --- | --- | --- |
| `speakup.stt` (exists) | analysis | Speech-to-text engines, `Word`, `Transcript`, `Engine`, `registry.all_engines()` |
| `speakup.text` | analysis | Token normalization |
| `speakup.analysis` | analysis | Acoustics, disfluency rules, metrics, nervousness signs, `Thresholds`, finalization, metric comparison |
| `speakup.coaching` | coaching | Claude calls, coaching prompt and rubric files, output validation, question generation, question bank |
| `speakup.store` | API and storage | SQLite schema, migrations, audio files |
| `speakup.pipeline` | API and storage | The worker that moves takes through stages |
| `speakup.api` | API and storage | FastAPI app, auth, errors, resources, the `speakup-server` command and its `launchd` plist |
| `speakup.config` (exists) | API and storage | New settings, listed in [Configuration](#configuration) |
| `ios/` | iOS | The SwiftUI app, an Xcode project for iOS 26 |

### Signatures

```python
# Shared aliases, defined in each consuming module (no shared types package).
AnalysisDoc = dict[str, Any]        # "Analysis output"
CoachingReportDoc = dict[str, Any]  # "Coaching report", stored form
MetricChange = dict[str, Any]       # one item of Comparison.metric_changes


# speakup.stt (exists): the pipeline picks the engine by name.
from speakup.stt.registry import all_engines
engine: Engine = all_engines()[settings.stt_engine]
engine.prepare()                                   # once, at worker start
transcript: Transcript = engine.transcribe(wav16k, audio_seconds)


# speakup.analysis
def analyze(*, take_id: str, wav16k: Path, transcript: Transcript,
            thresholds: Thresholds | None = None) -> AnalysisDoc:
    """Rules-only analysis. Raises NoSpeech when fewer than 5 words were transcribed."""

def finalize(analysis: AnalysisDoc, coaching: CoachingReportDoc | None) -> AnalysisDoc:
    """Pure. Applies filler rulings and annotations, recomputes metrics."""

def compare_metrics(previous: AnalysisDoc, current: AnalysisDoc) -> list[MetricChange]:
    """Pure. Both finalized. The fixed metric list in "Comparison"."""

class NoSpeech(Exception): ...


# speakup.coaching
class PromptContext(TypedDict):
    kind: Literal["prepared", "impromptu"]
    text: str
    notes: str | None
    category: str | None
    target_seconds: int

class CoachingRequest(TypedDict):
    take_id: str
    mode: Literal["home", "driving"]   # driving may later select a faster model
    prompt: PromptContext
    attempt: int
    analysis: AnalysisDoc              # rules-only stage output of this take
    previous: PreviousTake | None      # set for a retry with a done previous take

class PreviousTake(TypedDict):
    attempt: int
    analysis: AnalysisDoc              # finalized
    coaching: CoachingReportDoc | None # None: no focus items to judge, comparison stays null

class CoachingUnavailable(Exception): ...   # no API key
class CoachingFailed(Exception): ...        # API or validation failure after retries

def coaching_info() -> dict[str, Any]:
    """{"available", "model", "rubric_version", "prompt_version"} for /v1/health."""

def coach_take(request: CoachingRequest) -> CoachingReportDoc:
    """One Claude call (plus at most one re-ask). Returns the stored form of the report."""

def generate_questions(*, count: int, category: str | None,
                       exclude: list[str]) -> dict[str, Any]:
    """{"source": "claude" | "bank", "questions": [...]}. Never raises for a missing key."""


# speakup.pipeline
class Analyzer(Protocol):   # satisfied by the speakup.analysis module
    def analyze(self, *, take_id: str, wav16k: Path, transcript: Transcript) -> AnalysisDoc: ...
    def finalize(self, analysis: AnalysisDoc, coaching: CoachingReportDoc | None) -> AnalysisDoc: ...
    def compare_metrics(self, previous: AnalysisDoc, current: AnalysisDoc) -> list[MetricChange]: ...

class Coach(Protocol):      # satisfied by the speakup.coaching module
    def coaching_info(self) -> dict[str, Any]: ...
    def coach_take(self, request: CoachingRequest) -> CoachingReportDoc: ...
    def generate_questions(self, *, count: int, category: str | None, exclude: list[str]) -> dict[str, Any]: ...

class Worker:
    def __init__(self, store: Store, engine: Engine, analyzer: Analyzer, coach: Coach) -> None: ...
    def start(self) -> None: ...    # resumes unfinished takes, then waits for work
    def wake(self) -> None: ...     # called after an upload or reprocess
    def stop(self) -> None: ...


# speakup.api
def create_app(*, store: Store | None = None, worker: Worker | None = None,
               coach: Coach | None = None) -> FastAPI:
    """Defaults build the real store, engine, analysis and coaching from settings; tests pass fakes."""
```

Fakes for parallel work:

- **Analysis** needs no fakes: it takes a WAV and a `Transcript`, and the bake-off's saved transcripts in `data/bakeoff/` are real inputs.
- **Coaching** feeds the [analysis example](#analysis-example) (and its own variations) to `coach_take`, and checks the output against the [Coaching report](#coaching-report) rules.
- **API and storage** passes an `Analyzer` and a `Coach` that return the doc examples, and an `Engine` that returns a fixed `Transcript`, so the whole lifecycle runs in tests without models or keys.
- **iOS** runs against a mock server or a stub `URLProtocol` that serves the endpoint examples, and against the real server once it exists.

## Pipeline orchestration

One worker thread, started by the FastAPI app's lifespan, processes one take at a time, oldest `recorded_at` first among takes that are not `done` or `failed`.
One at a time keeps the GPU to one speech-to-text job and guarantees a retry's previous take is finished before the retry reaches coaching, since it was recorded earlier.
Uploads, polling and question generation are served by the API concurrently with the worker.

For each take, the worker runs the stages in order, setting `status` before each and saving each output before moving on:

1. **`transcribing`:** convert `original.wav` to `audio16k.wav` (`audio_invalid` on failure), run the engine, save the transcript.
2. **`analyzing`:** `analyze(...)`, save `stage_json`, and save `final_json = finalize(stage, None)`.
   `NoSpeech` fails the take with `no_speech`.
3. **`coaching`:**
   - If `coaching_info()["available"]` is false: set `coaching_status: "unavailable"` and go to done.
   - Otherwise resolve `previous_take_id`, build the `CoachingRequest`, and call `coach_take`.
     On success, save the report, rewrite `final_json = finalize(stage, report)`, and set `coaching_status: "done"`.
     On `CoachingFailed` or `CoachingUnavailable`, set `coaching_status` to `failed` or `unavailable` and log the reason.
4. **`done`.**

Retries:

- **Speech to text:** a cloud engine's network or 5xx error is retried twice, after 5 and 30 seconds; then the take fails with `stt_failed`.
  A local engine error is not retried.
- **Analysis:** never retried; it is deterministic, so a failure is a bug (`analysis_failed`).
- **Coaching:** the Anthropic SDK retries 429, 5xx and connection errors (`max_retries=2`); an invalid output is re-asked once; then `coaching_status: "failed"`.
- **Server restart:** at startup the worker resumes every take in `uploaded`, `transcribing`, `analyzing` or `coaching` from the start of its current stage.
  Each stage replaces its own output, so rerunning is safe.
- **Manual:** `POST /v1/takes/{take_id}/reprocess` reruns from any stage.
  Nothing is retried automatically after a take is `done` or `failed`.

When coaching is unavailable, the take still finishes: the report shows the annotated transcript (lexical fillers judged by rules) and the metrics, with no verdict, strength, focus, dimension levels, outline or reference version, and the app explains why and offers "Get coaching" once the server reports coaching as available.
A retry without coaching still gets a comparison with metric changes only.

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
Engines write the same speech differently ("[UM]", "Um,", "th-", "(laughter)"), so analysis normalizes tokens first (`speakup/text.py`).

Ruled out: Whisper and its variants (they drop fillers), OpenAI's newer transcription models (no word timestamps), Parakeet and Canary (weak on fillers).
Evidence and alternatives are in [research.md#speech-to-text](research.md#speech-to-text).

## Configuration

Secrets live in ignored files only: the Anthropic API key, any speech-to-text API key, and the server bearer token.
The server reads them from the environment, then from `server/.env`; `server/.env.example` lists the names.
The app keeps the server address and token in the Keychain.

Server settings added in M1 (the API implementer adds them to `server/.env.example`):

| Name | Default | Meaning |
| --- | --- | --- |
| `SPEAKUP_API_TOKEN` | none; the server refuses to start without it | Bearer token the app sends |
| `ANTHROPIC_API_KEY` | none | Coaching and question generation; without it coaching is unavailable and questions come from the bank |
| `SPEAKUP_DATA_DIR` | `data/server` in the repository | Database, audio and `profile.md` |
| `SPEAKUP_STT_ENGINE` | `crisperwhisper` until the bake-off decides | Engine name from `registry.py` |
| `SPEAKUP_COACH_MODEL` | `claude-opus-5-5` | Claude model for coaching and questions |
| `SPEAKUP_PORT` | `8765` | Local port behind `tailscale serve` |

## Data and privacy

Recordings contain Ryan's work content.

- Audio, transcripts and reports are stored on the Mac mini and cached on the iPhone.
- Transcripts, and the prompts and prepared notes that contain work context, are sent to Anthropic for coaching.
- The work-context profile (`profile.md`) and recent impromptu questions are sent to Anthropic to generate new questions.
- Audio is sent to ElevenLabs only if Scribe wins the bake-off.
- During the bake-off only, the test recordings go to ElevenLabs and, when its key is set, to AssemblyAI.

Any new service that receives audio or transcripts is added to this list in the same change.
