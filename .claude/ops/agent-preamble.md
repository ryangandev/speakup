# Agent preamble

Rules every subagent working in this repository follows.
A task brief adds only what is specific to the task.

## Writing

- Never use the em dash character. Use a plain hyphen or rephrase.
- In Markdown, keep each full sentence on its own line.
- Docs are in English. Update the doc that owns a fact in the same commit that changes it; ownership is in `docs/README.md`.

## Commits and branches

- Work only on the branch and worktree the brief names. Commit as you go with clear messages.
- Never add a co-author or agent attribution line to commit messages.
- Do not merge, rebase `main`, push to `main`, change repository settings, or delete branches you did not create.
- There may be no GitHub remote yet. If `git remote` is empty, do not create one: commit locally and report the branch and head SHA.

## Secrets and data

- Never print, log or commit API keys. Keys live in `server/.env`, which git ignores.
- Never commit anything under `data/`: it holds Ryan's recordings and transcripts.
- Do not send audio or transcripts to any service not listed in `docs/architecture.md#data-and-privacy`.

## Commands

- Keep each shell command plain: no nested `bash -c` with `$?` or `$(...)`, no background `&` loops.
- Python: work from `server/` with `uv run ...`. Run only the tests covering your change while working; `uv run ruff format` and `uv run ruff check` before committing.
- Heavy jobs (xcodebuild, simulator runs, local CrisperWhisper transcription) run one at a time per agent; the orchestrator limits how many agents run them at once.
- Use only the simulator the brief assigns, and shut it down when you finish.

## Quality

- Reproduce a bug before fixing it.
- If you see a failing test or a warning, even outside your task, report it; fix it only if it is inside your scope.
- Stop and report instead of guessing when the plan does not hold, the scope grows, or a check fails for a reason outside your task.

## Shared files during parallel M1 work

- Do not edit `server/pyproject.toml` or `server/uv.lock`: every dependency M1 needs is already there. If you need another, stop and ask the orchestrator.
- Do not edit `AGENTS.md`, `docs/README.md` or `docs/status.md`. Put proposed changes (new commands, status lines) in your report; the orchestrator applies them.
- `docs/architecture.md` and `docs/product.md` are the contract. Do not edit them to fit your code. If the contract is wrong or impossible, stop and report; if you deviate in a small way, list it in your report.
