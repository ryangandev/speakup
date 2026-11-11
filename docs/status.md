# Status

## Now

Milestone 1, home practice end to end, as defined in [product.md#roadmap](product.md#roadmap).
The analysis server is built and runs end to end on synthesized takes: upload, transcription with local CrisperWhisper, analysis, a retry linked to its previous take, and the comparison.
Coaching runs against Claude: the key is in `server/.env`, and a synthesized take and its retry got a full report and a comparison on 2026-11-09, about 30 s for coaching.
It has not yet seen Ryan's real recordings, so the prompt and rubric are still v1.
The analysis rules have only seen synthesized speech; their block thresholds (0.5 s inside a phrase, 1.0 s for a pause plus a filler between ideas) are starting values to calibrate on Ryan's recordings.
Mandarin practice works end to end (2026-11-10): Home has an English / 中文 switch, a Chinese take is transcribed locally by Qwen3-ASR 1.7B, analyzed per character (嗯 and 呃, 那个 and 就是 as fillers, repetitions), and coached by Claude in Chinese.
It has run on synthesized Chinese clips through a real server and the simulator, not yet on Ryan's own Chinese speech; the Chinese filler rules and thresholds are uncalibrated.
The iPhone app is one simple loop (2026-11-09): Home picks a topic (a question on one of Ryan's interest themes or a work category, or Ryan's own) and a length, Record, and the report opens as soon as analysis is done, showing the transcript and metrics while Claude's feedback fills in.
It runs end to end against the real server in the simulator: settings, a take, its report, a retry and the comparison.
It still uses system colors; the visual direction below is not applied yet, and it has not run a take on a real iPhone.
Driving mode (M2) is set aside: its code and tests stay, but Home hides it (see [product.md#driving-mode](product.md#driving-mode)).
It runs end to end in the simulator with a scripted recognizer, and the real recognizer passes all spoken clips on the Mac with `tools/drive-commands`.
On Ryan's iPhone (2026-11-09) it read the questions aloud but missed short answers: a lone "three" came back from the recognizer as an empty result, while a full answer and "done" were heard.
The `.measurement` audio mode left speech at about -45 dBFS, but the Mac clips pass at that level too, so the level alone does not explain it.
A Debug build launched with `-debug.recognizerCapture` records the recognizer's input and results for `drive-commands --replay`, which is the next step when the drive comes back.
The visual direction is in [design/README.md](design/README.md), with a clickable prototype.
The M0 speech-to-text bake-off is built and waits on Ryan's recordings; see [bakeoff.md](bakeoff.md).

## Decided with Ryan

- v1: English, work scenarios, deliberate practice, used only by Ryan.
- Both prompt types: prepared and impromptu.
- Practice happens while driving and at home; driving mode is fully hands-free.
- Feedback is direct, covers strengths and problems, and is not nitpicky.
- Take length follows the prompt.
- iPhone only, SwiftUI.
- Analysis runs on the home Mac mini as a server; coaching uses Claude.
- Working codename: SpeakUp.
- 2026-11-11: the Question page has two tracks, Interests (themes learned from Ryan's own topics, editable, easy to hard) and Work.
  Claude writes questions in the Home language.
- 2026-11-10: Chinese practice now, the same loop as English, mostly with Ryan's own topics.
  Notes can stay open while recording, by a switch on Home.
- 2026-11-10: History is grouped by day, not by session, and the screens drop explanatory captions to stay plain.
- 2026-11-09: build the core loop first, simply: open the app, pick a topic and a length, record, see the transcript and metrics right away, then Claude's report. Driving mode and the prepared/impromptu split come later; no nervousness self-ratings for now.

## Waiting on Ryan

1. Record 10 to 15 takes for the bake-off and put them in `data/bakeoff/clips/`, as [bakeoff.md#run-it](bakeoff.md#run-it) describes, including at least three in the car.
   Then correct three or four gold transcripts; the tool drafts them.
2. Write a short work-context profile for impromptu questions: role, team, current projects, kinds of conversations that are hard.
   Leave out anything your employer would not want sent to Anthropic.
3. Run a take on the iPhone: connect it and pick it as the run destination in Xcode (the SpeakUp target is signed with your team).
   The build bundles the tailnet address and token (`ios/scripts/write-local-server.sh`), so Settings needs nothing.
   Tailscale is set up on the Mac mini and the iPhone and the server is published to the tailnet (2026-11-09), but it still runs from a terminal: keep the Mac mini awake, and move it to launchd as [server.md](server.md) describes.
4. Put an ElevenLabs API key in `server/.env` for the bake-off (`server/.env.example` shows the names), and an AssemblyAI key if you want it compared too.
5. Driving mode decisions, for when it comes back:
   1. Prepared prompts in the car: impromptu only (built), or also a "for the drive" queue built at home and read aloud before the tone.
      The agent recommends impromptu only for M2.
   2. Interrupting the app while it talks: today it finishes what it is saying before it listens.
      The agent recommends the steering-wheel next or pause button skipping the current speech, because the better version can run for a minute.
   3. Starting on a locked phone, and going on after a call: this needs a Live Activity on the lock screen and `AudioRecordingIntent`, which means a widget extension; it is not built until this is decided.
      Today Siri asks to unlock first, and a call pauses the drive.
   4. Late feedback: when waiting gives up, should the feedback be spoken later in the same drive, once it is ready?
      Today it is only in History.
      The agent recommends yes, at the next break.
6. When driving mode comes back: run a drive on the iPhone in the car, with AirPods, with the phone locked, with a call mid-take, and with a navigation prompt, and say how the defaults below feel.

## Open decisions

- Speech-to-text engine: CrisperWhisper on the Mac mini or ElevenLabs Scribe v2, decided by the M0 bake-off.
- Whether the car's hands-free microphone is good enough, or the app should force the iPhone microphone.
- Which Claude model for driving mode, balancing quality and latency.
- Does Ryan's car support CarPlay, and is it worth requesting the conversational app entitlement in M3?
- M1 defaults set by an agent in the contract, pending Ryan's review: a retry is compared with the previous take, not the first; a session closes by itself 2 hours after its last take; takes stop at 15 minutes; the work-context profile is a file on the Mac mini; no deleting takes in M1; impromptu practice needs the server in M1.
- Driving mode defaults set by an agent, to calibrate on a device: "done" needs 0.6 s of silence before it and 1.2 s after; each recognizer finalization waits 1.5 s for late words, so the app acts about 3.5 s after "done"; feedback waits 120 s; a drive ends after 10 minutes with no command; a take stops at 6 minutes; when iOS never reports the end of an interruption, the drive asks for the audio back after 3 minutes.

## Next steps

1. Restart the server (`uv sync --extra crisper --extra qwen`, then `uv run speakup-server`), then record a Chinese take on the iPhone and check that real 嗯 and 呃 survive transcription.
2. Run a take on Ryan's iPhone over Tailscale: recording level with the `.measurement` audio mode, upload, the report opening at analysis, then coaching; check background upload with the phone locked.
3. Run the bake-off on Ryan's recordings and record the engine decision in [architecture.md#speech-to-text](architecture.md#speech-to-text).
4. Iterate the coaching prompt and rubric v1 on the same recordings with Ryan.
5. Calibrate the block thresholds (and the Chinese filler rules) in `speakup.analysis.thresholds` on Ryan's recordings.
6. Set up the server on the Mac mini as [server.md](server.md) describes, outside `~/Documents`.
7. Apply the visual direction in [design/README.md](design/README.md) to the iOS app's `Theme` and screens.
8. Later, driving mode (M2): replay a captured phone run to find why short answers are missed, settle its decisions under Waiting on Ryan, then a device run in the car.

## Known issues

- `PUT /v1/takes` reads the database on the event loop; harmless with SQLite WAL, but it belongs in a thread.
- A chunked upload without `Content-Length` is spooled in full before the 100 MB limit applies.
- Session list paging can skip a session whose `started_at` ties at a page boundary.
- The analysis misses a restart that has no pause, comma or written cut-off; coaching's self-correction annotation covers it.
- Without an Anthropic API key, work questions come only from the built-in bank, which runs out after 8 per category, and interest questions from templates; themes are not learned.
- iOS: the tab bar is hidden on pushed practice screens.
- Chinese: a repetition is missed when the engine splits the two copies differently (我们 then 我 们), and `/v1/health` reports only the English engine.
- Chinese: without Claude, work questions come from the English-only bank.
- iOS: a recording cut off by an app crash is not recovered.
- iOS: if the server is rebuilt, takes the phone already uploaded are not sent again.
- Driving mode: a coaching instruction that quotes an unfinished example, such as the contract's "Second, ...", is read aloud cut short ("Second.").
- Driving mode: the scripted recognizer in the simulator places words by script time, not by the audio, so the simulator tests prove the cut at "done" only for clips whose script matches them.
- Driving mode: a navigation prompt spoken during a take is recorded into it.

## Deliberately not doing

See [product.md#out-of-scope-for-v1](product.md#out-of-scope-for-v1).
