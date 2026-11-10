# Research

External findings behind product and architecture decisions, checked on 2026-11-09.
Vendor benchmarks and aggregator prices are marked; re-check them before relying on them.

## Competitors

| App | Focus | Gap relevant to SpeakUp |
| --- | --- | --- |
| Yoodli | AI roleplay for interviews and sales; fillers, pace, word choice, progress dashboard | No visible "retry the same prompt and compare" loop |
| Orai | Courses; clarity, pace, fillers, confidence | Reviewers say it cannot judge logical structure |
| Speeko | Daily exercises; pace, pauses, intonation | Flags fillers without context (counts "well" even when meaningful) |
| Poised | Live overlay in real meetings | Not a practice tool; listens to meeting audio |
| Speak, ELSA, Praktika | Language learning and pronunciation | Not communication coaching; complaints about lenient scores and billing |
| ChatGPT Voice, Gemini Live | Ad hoc mock interviews | No annotated transcript, metrics or comparison |
| speaking.app (Jan 2026) | "Anti-rambling", rewrites answers into STAR or PREP | Closest concept; very small |
| 微演说, 智能口才大师, 口才精灵 | Chinese scoring and roleplay | No deep evaluation of structure |

The open space: structure and content coaching, the immediate retry with comparison, context-aware filler and pause feedback, and an audio-only coach for the car.

Retention risks seen across these apps: no visible progress, repetitive prompts, scores that feel meaningless, nitpicky false positives, and generic AI feedback.
The steepest drop-offs are after the first session, on days 3 to 5 and on days 10 to 14.

Sources: https://prospeo.io/s/yoodli-pricing-reviews-pros-and-cons, https://www.bilibili.com/read/cv45191754, https://setapp.com/apps/speeko/customer-reviews, https://cybernews.com/ai-knowledge-base/tools/poised/, https://languatalk.com/blog/speak-app-review/, https://www.producthunt.com/products/speaking-app/launches, https://cmotech.uk/story/uk-language-app-users-invest-time-money-but-lack-confidence.

## Practice methods

- **Structure frameworks:** PREP (point, reason, example, point) for impromptu answers; the pyramid principle for answer-first, layered structure; STAR for stories and decisions.
- **Impromptu drills:** Toastmasters Table Topics run 1 to 2 minutes; a common failure is ending abruptly.
  https://www.toastmasters.org/magazine/magazine-issues/2017/oct-2017/table-topics
- **Filler reduction:** awareness training, alone or with a competing response such as pausing silently, reduced filled pauses for every participant in two small studies (Mancuso and Miltenberger 2016; Montes et al. 2019).
  Hearing each instance matters more than a score.
  https://zendy.io/title/10.1002/jaba.267, https://zendy.io/title/10.1002/jaba.569
- **Filler baseline:** about 2 to 6 filled pauses per 100 words in ordinary spontaneous speech (Bortfeld et al. 2001).
  https://pmc.ncbi.nlm.nih.gov/articles/PMC9014665
- **Pause threshold:** 250 to 300 ms is the best-supported silent-pause threshold for fluency measures (de Jong and Bosker 2013).
  Pauses inside a clause hurt perceived fluency most; pauses at boundaries sound natural.
  https://www.mpi.nl/publications/item1900232/choosing-threshold-silent-pauses-measure-second-language-fluency
- **Speaking rate:** telephone conversation averages about 196 words per minute, ranging 111 to 291 (Yuan, Liberman and Cieri 2006).
  The often-quoted 150 words per minute is practitioner lore.
  https://www.isca-archive.org/interspeech_2006/yuan06_interspeech.html
- **Nervousness:** saying "I am excited" before speaking produced speeches rated more persuasive and confident than "I am calm" (Brooks 2014).
  Repeated low-stakes practice is the other lever.
  https://www.apa.org/news/press/releases/2013/12/performance-anxiety

## Speech to text

Most disfluency and timestamp numbers come from Nyra Labs, which makes CrisperWhisper, so treat them as vendor benchmarks.
F1 is the detection score, from 0 to 100; higher is better.

| Engine | Keeps fillers | Word timing error | Cost | Mandarin, mixed speech |
| --- | --- | --- | --- | --- |
| ElevenLabs Scribe v2 (cloud) | Yes by default; filler F1 95.5, disfluency F1 90.3 | about 60 ms conversational | about $0.22 per hour | Mandarin yes; mixed not documented |
| CrisperWhisper 2.0 (local) | Yes; filler F1 94.3, disfluency F1 90.7 | about 41 ms conversational | Free; non-commercial weights; no MLX | Most Whisper languages |
| AssemblyAI Universal-3.5 Pro | By prompt; docs disagree on the flag | Yes | about $0.21 per hour | Mandarin and mixed speech |
| Deepgram Nova-3 | um and uh only; filler F1 45.7 | about 88 ms | unverified | Mandarin since Mar 2026 |
| OpenAI gpt-4o-transcribe | By prompt only | None | unverified | Yes |
| Whisper large-v3, WhisperX | Mostly removed; filler F1 9.4 | about 93 ms (WhisperX) | Free | Good Mandarin |
| Parakeet, Canary | Weak; Canary filler F1 26.7 | Good | Free | Parakeet v3 is European only |
| Apple SpeechTranscriber (iOS 26) | Reported to keep um and uh | Yes | Free, on device | No benchmark |

Lexical fillers ("like", "so") are not tagged by any engine and need classification in context.

Chinese engines tend to remove 嗯, 呃, 那个 and 就是, which must be tested on Ryan's casual speech.

Local Mandarin candidates, measured on 2026-11-10 on five synthesized clips (21 to 27 s, dense with fillers, repetitions, a restart, English terms and pauses), clean and with noise at 8 dB SNR, on an M5 Pro:

| Engine | Fillers kept (clean / noisy, of 49) | Repetitions (of 23) | Character error (clean / noisy) | Timestamps | English terms | Real-time factor | License |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Qwen3-ASR 1.7B + ForcedAligner 0.6B (chosen) | 48 / 48 | 23 | 0.9% / 2.0% | Per character or Latin word; every pause shows | Right | 0.06 | Apache-2.0 |
| Qwen3-ASR 0.6B + ForcedAligner | 49 / 48 | 23 | 1.5% / 0.9% | Same | Sometimes wrong ("post girls") | 0.04 | Apache-2.0 |
| SeACo-Paraformer-zh (FunASR) | 45 / 42; writes 呃 as 恶 | 22 | 3.5% / 4.7% | Per character | Weak | 0.05, CPU only | Apache-2.0 |
| SenseVoiceSmall | 48 / 46 | 23 | 4.4% / 4.9% | Marks only, no durations | Weak | 0.05 | FunASR license |
| Fun-ASR-Nano-2512 | 48 | 23 | 5.2% | None in the released checkpoint | Weak | 0.03 | Apache-2.0 |
| CrisperWhisper large, `zh` | 46 | 22 | 11% | Yes | Right | 0.88 | Non-commercial |

The one filler every engine missed was a quirk of the synthetic voice; Apple's zh-CN model would not download for the test.
Synthesized speech says every filler clearly, so the choice still has to hold on Ryan's real takes.

Sources: https://www.nyra-labs.com/research/nyra-verbatim-speech-benchmark, https://www.nyra-labs.com/research/attention-to-aligner, https://github.com/nyrahealth/CrisperWhisper, https://elevenlabs.io/pricing/api, https://elevenlabs.io/docs/overview/capabilities/speech-to-text, https://www.assemblyai.com/docs/pre-recorded-audio/filler-words, https://developers.deepgram.com/docs/filler-words, https://developers.openai.com/api/docs/guides/speech-to-text, https://arxiv.org/abs/2509.12508.

## Commute design

- iOS 26.4 (Feb 2026) added a CarPlay category for voice-based conversational apps.
  It needs an entitlement Apple must approve; the app must open straight into voice, keep text and images out of its responses, and use Apple's templates.
  https://developer.apple.com/carplay/, https://9to5mac.com/2026/02/18/ios-26-4-adds-support-for-voice-based-ai-apps-to-carplay/
- ChatGPT has been on CarPlay since April 2026.
- There is no public API for AirPods head gestures; use media controls, Siri and App Intents, and Live Activities.
