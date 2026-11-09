# Status

## Now

Milestone 0, validation, as defined in [product.md#roadmap](product.md#roadmap).
Positioning, scope, the practice loop, feedback rules and the system shape are written in [product.md](product.md) and [architecture.md](architecture.md).
The speech-to-text bake-off is built and works end to end; it is waiting on Ryan's recordings.
How to run it is in [bakeoff.md](bakeoff.md).
The M1 system contract (data shapes, API, storage, module boundaries and screens) is written in [architecture.md#domain-model](architecture.md#domain-model) onward and [product.md#screens](product.md#screens), so M1 can be built in parallel.

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
2. Write the coaching prompt and rubric v1 and iterate it on the same recordings with Ryan.

## Deliberately not doing

See [product.md#out-of-scope-for-v1](product.md#out-of-scope-for-v1).
