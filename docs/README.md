# Docs

These docs route work on this repository; they are not an archive.
Load only the document and section a request needs.

## Route the request

| Question | Read |
| --- | --- |
| What is decided, what is open, and what is waiting on Ryan? | [status.md](status.md) |
| Who the app is for, what it does, and what it deliberately does not do | [product.md](product.md) |
| What a practice session, a prompt or a take is | [product.md#practice-loop](product.md#practice-loop) |
| What feedback says, how it is graded, and its tone | [product.md#feedback](product.md#feedback) |
| How fillers, blocks, repetitions and pace are measured | [product.md#metrics](product.md#metrics) |
| Hands-free practice in the car | [product.md#driving-mode](product.md#driving-mode) |
| Milestones and their order | [product.md#roadmap](product.md#roadmap) |
| System shape, components and why | [architecture.md](architecture.md) |
| What the iOS app's screens show, their actions and navigation | [product.md#screens](product.md#screens) |
| Ids, entities, and a take's lifecycle states | [architecture.md#domain-model](architecture.md#domain-model) |
| The analysis JSON: words, events, metrics, nervousness signs | [architecture.md#analysis-output](architecture.md#analysis-output) |
| The coaching report and retry comparison JSON | [architecture.md#coaching-report](architecture.md#coaching-report) |
| Server endpoints, request and response bodies, auth and errors | [architecture.md#server-api](architecture.md#server-api) |
| SQLite tables and the audio file layout | [architecture.md#storage](architecture.md#storage) |
| Which Python package owns what, and the functions between them | [architecture.md#module-boundaries-and-ownership](architecture.md#module-boundaries-and-ownership) |
| How a take moves through stages, retries, and running without coaching | [architecture.md#pipeline-orchestration](architecture.md#pipeline-orchestration) |
| Server settings and secrets | [architecture.md#configuration](architecture.md#configuration) |
| Which speech-to-text engine and why | [architecture.md#speech-to-text](architecture.md#speech-to-text), [research.md#speech-to-text](research.md#speech-to-text) |
| Running the M0 bake-off, reading its report, and deciding | [bakeoff.md](bakeoff.md) |
| Which files a change touches | [architecture.md#code-map](architecture.md#code-map) |
| Competitors, practice methods and the numbers behind thresholds | [research.md](research.md) |

List a document's headings with `rg '^##' docs/<file>.md` and read only the matching section.

## Ownership

- `AGENTS.md` holds commands and the rules that fail silently when broken.
  It loads into every session, so it stays short and links here for the reasons.
  `CLAUDE.md` only imports it, so Claude Code and Codex read the same text.
- `status.md` says what is true now and what is left.
  Resolved items are deleted, not archived.
- `product.md` is the behavior contract: what the app does and why.
- `architecture.md` says how each part works, why it is built that way, and where its code is.
  It holds no history.
- `bakeoff.md` owns the M0 bake-off procedure and decision criteria.
- `research.md` holds external findings with sources and dates.
  Update an entry when a re-check changes it; do not stack old versions.
