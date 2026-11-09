# Product

SpeakUp is a deliberate-practice speaking coach.
It helps one person say what they mean clearly: get to the point, structure it in layers, stay on topic, and speak without blocks or filler.

## Positioning

- **For whom:** Ryan first, as a tool for his own improvement.
  Making it a product for others is a later decision, made only after it works for Ryan.
- **Language:** English first.
  Mandarin, and Mandarin mixed with English, come later.
- **Scenario:** work first: stand-up updates, explaining decisions, answering questions.
  Casual conversation with friends and "deep talk" (expressing a considered idea) come later as extra practice modes, not separate apps.
- **Mode:** deliberate practice.
  The user speaks alone on purpose; the app never records real meetings or other people.
  This keeps every recording single-speaker and avoids consent and diarization problems.

### What makes it different

Most speaking apps grade delivery: pace, filler counts, a total score.
SpeakUp puts structure and content first, because that is where Ryan's problems are and where competitors are weak.
Its core is the immediate retry: the same prompt, recorded again two minutes later, compared side by side.
See [research.md#competitors](research.md#competitors).

## Problems it targets

| Problem | Layer | Measured from |
| --- | --- | --- |
| Blocking, getting stuck | Fluency | Pauses inside a phrase, restarts, word timestamps |
| Filler words | Fluency | Verbatim transcript, with context for words like "like" and "so" |
| Repetition and rambling | Content | Transcript, LLM |
| No layered structure | Content | Transcript, LLM |
| Drifting off topic | Content | Transcript and prompt, LLM |
| Nervousness | State | Self-rating plus indirect signs; never a direct score |

## Practice loop

A **session** is one sitting, at home or in the car.
It holds one or more **prompts**, and each prompt holds one or more **takes** (recordings).

1. **Choose a prompt.**
   - **Prepared:** Ryan rehearses real content, such as today's stand-up.
     He may type or dictate his points first; the app then judges how he delivers and structures them.
   - **Impromptu:** the app asks a question and Ryan answers right away.
     Questions are generated for his work context, such as "Why did you choose X over Y?", "Give a status update on a project that is behind", "Explain a concept to a new teammate", or "Push back on a request".
     This is the main drill for blocking, drifting and structure.
2. **Record a take**, usually 1 to 3 minutes.
   Length depends on the prompt; the app suggests a target and does not cut the take off.
3. **Get feedback** on the take. See [Feedback](#feedback).
4. **Retry the same prompt** and get a comparison with the previous take: what improved, what still slipped.
   This is the core of the product.
5. Move to the next prompt or end the session.

Before and after a session, Ryan rates his nervousness from 1 to 5.

## Feedback

Feedback is direct.
It names what was good and what was not, without softening, and without nitpicking.

Each take gets:

- **Verdict:** one or two sentences on how the answer landed overall.
- **Strength:** one specific thing that worked, with a quote.
- **Focus:** one or two things to fix in the next take, each with a quote or timestamp and a concrete instruction.
  Only the issues that matter most are named; minor issues are left out so the next take has a clear target.
- **Structure outline:** the points Ryan actually made, in order, and whether the main point came first.
- **Annotated transcript:** fillers, blocks, repetitions, restarts and off-topic stretches marked inline, with audio playback.
- **Reference version:** Ryan's own content, restructured answer-first and in layers.
  It is a model of structure, not a script to memorize.
- **Metrics:** see [Metrics](#metrics).

The retry comparison says, for each focus item, whether it improved, and shows metric changes.

### Grading

There is no single total score in v1: a total hides what to change and feels arbitrary.
Each dimension gets a level (for example strong, okay, needs work) with the evidence behind it.

| Dimension | Good looks like |
| --- | --- |
| Answer first | The main point or conclusion is in the first one or two sentences |
| Layering | Points are signposted and grouped ("two reasons: first ... second ...") |
| Focus | Every part serves the question; no drifting |
| Concision | No restating the same thing; length fits the content |
| Fluency | Few blocks inside phrases, few restarts, fillers within the normal range |
| Close | The answer ends deliberately instead of trailing off |

Frameworks such as PREP, the pyramid principle and STAR inform the rubric and the reference version; the app does not force one template.
The rubric is versioned so results stay comparable over time.

## Metrics

Thresholds below are starting points, to be calibrated on Ryan's recordings in milestone 0.
Their sources are in [research.md#practice-methods](research.md#practice-methods).

- **Fillers:** filled pauses (um, uh) and lexical fillers (like, you know, so, basically, kind of) used as fillers, per 100 words.
  Ordinary spontaneous speech has about 2 to 6 per 100 words, so the goal is not zero.
  Each instance is listed with its timestamp, because hearing each one is what changes the habit.
- **Pauses:** silences of 250 ms or more, split by position.
  A pause at a sentence or clause boundary is normal and is not counted as a problem.
  A pause inside a phrase, or one followed by a filler or a restart, counts as a **block**.
- **Restarts and repetitions:** repeated words or phrases and abandoned starts ("we need to - we should migrate").
- **Pace:** words per minute over voiced time.
  Shown for information; not graded in v1.
- **Pitch and volume variation:** shown for information; not graded in v1.
- **Nervousness signs:** pace rising sharply, blocks clustering, pitch rising.
  Shown next to the self-rating, never as a "nervousness score".

## Driving mode

Ryan's commute is by car, so practice there must be completely hands-free and eyes-free.

- A session starts before driving, with one tap, by Siri ("start a SpeakUp drive"), or from CarPlay.
- After that, nothing needs a glance or a touch.
  The app speaks each prompt, plays a tone, and records.
- Ryan ends a take by saying "done".
  Silence does not end a take, because long pauses are part of what is measured.
  A take also ends at a generous maximum length.
- Feedback is spoken and short: the verdict, one strength, one focus item, and on request the reference version.
  The full annotated report waits for home.
- Voice commands: "again" (retry the prompt), "next", "repeat that", "read the better version", "stop".
- If the server cannot be reached, the app keeps the take, says feedback will come later, and offers the next prompt.
- Nervousness self-ratings are spoken.

CarPlay support depends on Apple granting the voice-based conversational app entitlement. See [research.md#commute-design](research.md#commute-design).

## Home mode

At home, Ryan uses the full screen:

- Practice with the complete visual report.
- Review driving sessions: annotated transcripts, outlines and comparisons.
- History: each metric and each dimension over time, and how the current focus item is trending.

## Out of scope for v1

- Recording real meetings or conversations, or anyone other than the user.
- Mandarin and mixed-language speech.
- Friend chat and deep talk modes.
- Video, facial expression and body language.
- Android and the Web.
- A total score, streaks and gamification.
- Accounts, sign-in and other users.

## Roadmap

Each milestone ends with Ryan using it for real before the next starts.

1. **M0, validation (no app):** Ryan records 10 to 15 takes, including some in the car.
   We compare speech-to-text engines on them and iterate the coaching prompt by hand until Ryan finds the feedback useful.
   Exit: an engine chosen, rubric and prompt v1 written, thresholds calibrated.
2. **M1, home practice:** the iPhone app records prepared and impromptu takes, the server analyzes them, and the app shows the full report, retry and comparison.
3. **M2, driving mode:** the hands-free voice loop, Siri start, spoken feedback and the offline queue.
4. **M3, progress and CarPlay:** history and focus tracking, and CarPlay if Apple grants the entitlement.
5. **Later:** Mandarin and mixed speech, friend chat and deep talk modes, and the decision whether to make it a product.

Home practice comes before driving because the feedback quality is the same problem in both, and it is far easier to judge and fix while looking at a screen.
