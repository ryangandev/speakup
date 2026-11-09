# Status

## Now

Milestone 1, home practice end to end, as defined in [product.md#roadmap](product.md#roadmap).
The analysis server is built and runs end to end on synthesized takes: upload, transcription with local CrisperWhisper, analysis, a retry linked to its previous take, and the comparison.
Coaching is built and tested against fakes; it has not run against Claude yet, because there is no Anthropic API key.
The analysis rules have only seen synthesized speech; their block thresholds (0.5 s inside a phrase, 1.0 s for a pause plus a filler between ideas) are starting values to calibrate on Ryan's recordings.
The iPhone app's home mode is built and runs end to end against the real server in the simulator: settings, a prepared take, its report, a retry and the comparison.
It still uses system colors; the visual direction below is not applied yet, and it has not run on a real iPhone.
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

## Waiting on Ryan

1. Record 10 to 15 takes for the bake-off and put them in `data/bakeoff/clips/`, as [bakeoff.md#run-it](bakeoff.md#run-it) describes, including at least three in the car.
   Then correct three or four gold transcripts; the tool drafts them.
2. Write a short work-context profile for impromptu questions: role, team, current projects, kinds of conversations that are hard.
   Leave out anything your employer would not want sent to Anthropic.
3. Install Tailscale on the Mac mini and the iPhone, and keep the Mac mini awake.
   To run the app on the iPhone, sign in to Xcode with your Apple account and pick your team for the SpeakUp target; it stays local, not committed.
4. Put an ElevenLabs API key in `server/.env` for the bake-off (`server/.env.example` shows the names), and an AssemblyAI key if you want it compared too.
   An Anthropic API key goes there later, for coaching.

## Open decisions

- Speech-to-text engine: CrisperWhisper on the Mac mini or ElevenLabs Scribe v2, decided by the M0 bake-off.
- Whether the car's hands-free microphone is good enough, or the app should force the iPhone microphone.
- Which Claude model for driving mode, balancing quality and latency.
- Does Ryan's car support CarPlay, and is it worth requesting the conversational app entitlement in M3?
- M1 defaults set by an agent in the contract, pending Ryan's review: a retry is compared with the previous take, not the first; a session closes by itself 2 hours after its last take; takes stop at 15 minutes; the work-context profile is a file on the Mac mini; no deleting takes in M1; impromptu practice needs the server in M1.

## Next steps

1. Run the bake-off on Ryan's recordings and record the engine decision in [architecture.md#speech-to-text](architecture.md#speech-to-text).
2. Iterate the coaching prompt and rubric v1 on the same recordings with Ryan, once an Anthropic API key is in `server/.env`.
3. Calibrate the block thresholds in `speakup.analysis.thresholds` on Ryan's recordings.
4. Set up the server on the Mac mini as [server.md](server.md) describes, outside `~/Documents`.
5. Apply the visual direction in [design/README.md](design/README.md) to the iOS app's `Theme` and screens.
6. Build driving mode (M2), then history and polish.
7. Run the app on Ryan's iPhone over Tailscale: check background upload with the phone locked, and recording with AirPods and the car's microphone.

## Known issues

- `PUT /v1/takes` reads the database on the event loop; harmless with SQLite WAL, but it belongs in a thread.
- A chunked upload without `Content-Length` is spooled in full before the 100 MB limit applies.
- Session list paging can skip a session whose `started_at` ties at a page boundary.
- The analysis misses a restart that has no pause, comma or written cut-off; coaching's self-correction annotation covers it.
- Without an Anthropic API key, impromptu questions come only from the built-in bank, which runs out after 8 per category.
- iOS: the tab bar is hidden on pushed practice screens.
- iOS: a recording cut off by an app crash is not recovered.
- iOS: if the server is rebuilt, takes the phone already uploaded are not sent again.

## Deliberately not doing

See [product.md#out-of-scope-for-v1](product.md#out-of-scope-for-v1).
