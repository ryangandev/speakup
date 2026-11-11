# Product

SpeakUp is a deliberate-practice speaking coach.
It helps one person say what they mean clearly: get to the point, structure it in layers, stay on topic, and speak without blocks or filler.

## Positioning

- **For whom:** Ryan first, as a tool for his own improvement.
  Making it a product for others is a later decision, made only after it works for Ryan.
- **Language:** English, and Mandarin Chinese since 2026-11-10, chosen per take.
  Mandarin mixed with English is transcribed as it comes but is not designed for yet.
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
5. Move to the next prompt.

Nervousness self-ratings from 1 to 5, before and after a session, are set aside for now (2026-11-09): only driving mode still asks for them.

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
  In Chinese the fillers are 嗯, 呃 and the like, plus 那个, 这个, 就是, 然后 used as fillers, counted per 100 characters; there is no calibrated norm for Chinese yet.
- **Pauses:** silences of 250 ms or more, split by position.
  A pause at a sentence or clause boundary is normal and is not counted as a problem.
  A pause inside a phrase, or one followed by a filler or a restart, counts as a **block**.
- **Restarts and repetitions:** repeated words or phrases and abandoned starts ("we need to - we should migrate").
- **Pace:** words per minute over voiced time; characters per minute in Chinese.
  Shown for information; not graded in v1.
- **Pitch and volume variation:** shown for information; not graded in v1.
- **Nervousness signs:** pace rising sharply, blocks clustering, pitch rising.
  Shown next to the self-rating when there is one, never as a "nervousness score".

## Driving mode

**Set aside (2026-11-09).** Ryan decided to focus on the core practice loop first; driving mode comes back later.
Its code and tests stay, but Home no longer offers it: only the `-showsDriving YES` launch argument shows the "Start a drive" card, and Siri can still start a drive.
On Ryan's iPhone it did not yet hear short answers such as "three"; [status.md](status.md) has what was found.

Ryan's commute is by car, so practice there must be completely hands-free and eyes-free.

- A drive starts before driving, with one tap on Home's "Start a drive" card, or by Siri.
  The Siri phrases are "Start a SpeakUp drive", "Start driving with SpeakUp" and "SpeakUp drive".
  Siri opens the app, so a locked phone asks to be unlocked first.
  CarPlay comes later.
- After that, nothing needs a glance or a touch.
  The screen shows what the drive is doing in large text, the question and the answers saved, with a Stop button, for a passenger or when parked.
  It stays awake while the drive runs, and ends on a summary of answers saved and feedback still to come.
- The drive opens with "SpeakUp drive. How nervous are you, one to five?".
  Ryan answers one to five, or "skip"; an unclear answer is asked once more, then skipped.
- Questions are impromptu: the server's, cached on the phone so a drive without a connection still has some, with a built-in list behind them.
  Each question is read aloud, then "Answer after the tone.", then a tone, and the take records.
- Ryan ends a take by saying "done" after a short pause.
  The take is cut just before "done", so the command is not in the recording.
  Silence does not end a take, because long pauses are part of what is measured.
  A take also ends at 6 minutes, with "That's the time limit."
- The app says "Got it." and waits for feedback for up to 120 seconds, saying "Still working." at 30 and 60 seconds.
  After that it says feedback on that answer will come later, and the report shows in History.
  Feedback that arrives later is not spoken in the same drive.
- Feedback is spoken and short: the verdict, one strength ("What worked:") and the first focus item ("Next time:").
  A retry leads with what changed, then the verdict and the new focus item.
  Without coaching, the app says "No coaching right now." and reads the filler rate, stalls and restarts, and pace.
  The full annotated report waits for home.
- Voice commands between takes, each said on its own:
  - "again" or "try again": the same question once more, as a retry.
  - "next" or "next question": a new question.
  - "repeat that" or "say that again": the last feedback again.
  - "read the better version" or "better version": the reference version from coaching.
  - "stop": the closing nervousness rating, then "Drive ended." with the number of answers saved.
  Anything else gets the list of commands.
- With no command for 10 minutes, the drive ends itself.
- If the server cannot be reached, the app keeps the take on the phone, says "I couldn't reach the server. Your answer is saved; feedback will come later.", and offers the next question.
  Kept takes upload when the server is reachable again, and wait on Home until then.
- Nervousness self-ratings are spoken.

CarPlay support depends on Apple granting the voice-based conversational app entitlement. See [research.md#commute-design](research.md#commute-design).

## Home mode

At home, Ryan uses the full screen:

- Practice with the complete visual report.
- Review driving sessions: annotated transcripts, outlines and comparisons.
- History: each metric and each dimension over time, and how the current focus item is trending.

## Screens

The M1 home-mode screens: what each shows, its primary actions, and how they connect.
Visual design is decided separately; this section is the behavior the app must have.
Screens stay plain: a label only where the content does not speak for itself, and no explanatory captions (2026-11-10).
Data shapes and endpoints are in [architecture.md#server-api](architecture.md#server-api).

### Navigation

```text
Practice tab
  Home ──▶ Recording ──▶ Processing ──▶ Report ──▶ Comparison
              ▲                           │
              └──── Retry (same prompt) ──┘
  Home ──▶ Settings (sheet)

History tab
  Days ──▶ Topic ──▶ Report ──▶ Comparison
```

The app has two tabs, Practice and History.
Recording and Processing are full-screen, so a take is never interrupted by navigation.
On first launch, with no server address or token, Settings opens first.

### Sessions in the app

Sessions group takes on the server; Ryan never sees or manages them, and History shows days instead.

- A session opens when Ryan records his first take with no session open.
- It stays open across topics and retries.
- If the app is opened more than 2 hours after the last take of an open session, it closes that session, with `ended_at` set to the end of its last take.
- The app no longer asks for nervousness self-ratings (2026-11-09, to keep the loop simple); a session's ratings stay empty, and the report shows the nervousness signs alone.

### Home

One screen: pick a topic, pick a length, record.

Shows:

- Server state only when something is wrong: unreachable, not set up, or reachable without coaching; a gear opens Settings.
- Language: **English** or **中文**, remembered between launches.
  The take is transcribed, analyzed and coached in that language, and Claude writes questions in it (the built-in work questions stay English).
- A **Question / Your own** switch.
  Question has two tracks, **Interests** and **Work**, by a small switch under it that is remembered between launches (Interests first).
  - Interests shows theme chips: Any, then Ryan's themes (pinned first), then **Edit**.
    Claude learns the themes from the topics Ryan types himself, such as "Happiness", "Charisma" or "Travel"; Edit opens a Themes sheet to add one, pin or unpin one, or swipe one away, and a removed learned theme is never suggested again.
    Questions start personal and reflective ("What does happiness mean to you?") and get harder as Ryan practises a theme: explaining and giving an opinion after three takes on it, then taking a side and answering a counterpoint after eight, with an easier one now and then.
  - Work shows category chips: Any, Decision, Status, Explain, Push back.
  - A chip shows one question in large text, under the name of its theme or category, with **Another question**.
    Questions are fetched three at a time for each track, chip and language; a small note says when they came from the built-in bank instead of Claude.
    If the server cannot be reached, it says so and offers Retry; Your own still works.
  - Your own shows a topic field (placeholder "Today's stand-up") and optional notes for the points Ryan wants to make (typed, or dictated with the keyboard's dictation key).
    A **Show notes while recording** switch under the notes, remembered between launches, opens them on the recording screen from the start, for an outline of the argument and its order.
- A target length picker: 30 seconds, 1, 1.5, 2, 3 or 5 minutes.
  A question brings its suggested length; Your own starts at the default from Settings (2 minutes).
- **Recent**: the open session's takes, newest first: prompt text, attempt number, and status or verdict.
  A take still on the phone shows "Not uploaded" with Retry upload.
- Takes of ended sessions still on the phone, such as a drive's offline takes, under "Waiting to upload".

Actions: **Record** (primary, pinned at the bottom; Your own needs a topic), Another question, change topic, open a take's Report, Settings.
After a take starts, Home moves on to the next question, or clears a typed topic, for the next take.

### Recording

Shows the prompt text, the prepared notes (open when Home's "Show notes while recording" is on, otherwise collapsed behind "Show notes"; a tap toggles them either way), the elapsed time against the target (it keeps counting past the target and never stops the take there; the bar turns orange), and a live input level.
The screen stays awake.

Actions: **Done** (primary; stops and keeps the take), Cancel (discards after a confirmation).
There is no pause button, because a paused take would hide real pauses.

Recording starts the moment Record is tapped.
A take is saved on the phone before it is uploaded.
At 14 minutes the screen warns, and at 15 minutes it stops and keeps the take; this is a technical limit, not a target.
If a phone call or another app interrupts recording, the take stops and is kept up to that point.

### Processing

Shows upload progress, then the stage from the take's status (Transcribing, Analyzing).
After 3 minutes it adds "Taking longer than usual".
As soon as analysis is done (the take's status is `coaching` or `done`), the app moves to the Report by itself: the transcript and metrics show at once, and Claude's feedback fills in when coaching finishes.

Actions: Back to Home (processing continues on the server and the take appears on Home), and on errors:

- Upload failed: "Saved on this phone" with **Retry upload**.
- No speech detected: **Record again** on the same prompt.
- Any other failure: the error message and **Try again**, which reprocesses the take.

### Report

Top to bottom:

1. Header: prompt text and length against target; the title is the attempt number.
2. For attempt 2 or later, a comparison card: the comparison summary and each previous focus item's outcome; tapping it opens Comparison.
3. **Verdict.**
4. **Strength**, with its quote; tapping the quote plays that audio.
5. **Focus**: one or two items, each with title, problem, quotes to play, and the instruction for the next take.
6. **Retry** as the primary action, pinned at the bottom of the screen, with New topic below it.
7. **Dimensions**: six rows, each with its level and evidence.
8. **Structure outline**: the points in order with their roles, and whether the main point came first.
9. **Annotated transcript**: fillers, blocks, repetitions, restarts and off-topic stretches marked inline, boundary pauses shown faintly, with a legend.
   Tapping a word plays from there; tapping a mark explains it.
10. **Reference version**, collapsed until tapped.
11. **Metrics**: fillers per 100 words, blocks, restarts and repetitions; below a divider, ungraded, pace, pitch variation and volume variation.
    The fillers row expands to every filler with its timestamp and a play button.
12. **Nervousness**: the signs found in this take, never as a score, next to the session's self-ratings when it has any; left out when there is neither.

Until coaching is done, and without coaching, sections 3 to 5, 7, 8 and 10 are replaced by one banner; the transcript, metrics and nervousness remain, and the comparison card shows metric changes only:

- Coaching running: "Claude is reviewing this take. Its feedback appears here when it is done." The report fills in by itself when it is done.

- Coaching unavailable: "Coaching is off because the server has no Anthropic API key." When the server later reports coaching as available, the banner offers **Get coaching**, which reprocesses the take from coaching.
- Coaching failed: "Coaching failed for this take." with **Try coaching again**.

Actions: **Retry**, New topic (back to Home with the session still open), play audio.

### Comparison

Shows "Take n against take n - 1", the summary, each previous focus item with its outcome (improved, partly improved, not improved, not applicable), evidence and quote to play, the six dimension levels before and after, and the metric changes before and after (graded metrics marked better, same or worse; the ungraded ones below a divider).
Two play buttons play the two takes, so Ryan can hear the difference.
Without coaching on either take, only metric changes are shown, with a note why.

Actions: play either take, open either take's Report, **Retry** again.

### History

**Days:** one section per day (Today, Yesterday, then the date), newest first, loading more on scroll (2026-11-10).
Each row is a topic Ryan answered that day: its text, the time, and the number of takes.
A day is the day its session started.

**Topic:** the topic's text and its takes in order: attempt, length and verdict.
Tapping a take opens its Report.

Trends over time and focus tracking are M3, per [Roadmap](#roadmap).

### Settings

Shows and edits:

- Server address, such as `https://mac-mini.example-tailnet.ts.net`.
- Token, entered once and kept in the Keychain; shown masked.
- **Test connection**, which shows whether the server answered, the speech-to-text engine, whether coaching is available, the model and the rubric version.
- Default prepared length.
- App version.

### Later: what driving mode needs from this contract

Driving mode ([Driving mode](#driving-mode)) adds no M1 screens, but the M1 contract already supports it:

- Sessions carry `mode: driving`.
- The app creates ids itself, so takes recorded without a connection upload later in order, and repeated uploads are harmless.
- The verdict, strength, first focus item and reference version are plain sentences that can be read aloud.
- Driving sessions appear in History like home sessions, which is how Ryan reviews them at home.

## Out of scope for v1

- Recording real meetings or conversations, or anyone other than the user.
- Mixed Chinese and English speech as a designed case.
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
5. **Later:** mixed Chinese and English speech, friend chat and deep talk modes, and the decision whether to make it a product.

Home practice comes before driving because the feedback quality is the same problem in both, and it is far easier to judge and fix while looking at a screen.
