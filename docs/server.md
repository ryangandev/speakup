# Running the server

How to set up and run the analysis server on the Mac mini.
The API, storage and pipeline are specified in [architecture.md](architecture.md#server-api); this page is only about operating them.

## Where things must live

macOS privacy protection (TCC) blocks background jobs from reading `~/Documents`, `~/Desktop` and `~/Downloads`.
A job started by `launchd` that tries gets "Operation not permitted" and crash-loops.
So the server runs from a checkout and a data directory outside those folders:

- The checkout used for serving: `~/speakup`. Clone or copy the repository there; keep development checkouts wherever you like.
- The data directory: `~/Library/Application Support/SpeakUp`, set with `SPEAKUP_DATA_DIR`.

The alternative is granting Full Disk Access to the python binary that runs the server.
`server/.venv/bin/python` resolves to a uv-managed python under `~/.local/share/uv/python/`, and the grant is lost when uv replaces that python.
Moving the checkout is the more durable fix.

## Setup

1. From `~/speakup/server`, run `uv sync --extra crisper --extra qwen`. The first English transcription downloads the CrisperWhisper weights and the first Chinese one the Qwen3-ASR weights (several GB each).
2. Install ffmpeg with `brew install ffmpeg`. Without it the server falls back to macOS `afconvert`.
3. Copy `.env.example` to `.env` (ignored by git) and fill in:
   - `SPEAKUP_API_TOKEN`: at least 32 characters, or the server refuses to start. Generate one with `python3 -c "import secrets; print(secrets.token_urlsafe(32))"`.
   - `ANTHROPIC_API_KEY`: optional. Without it coaching is unavailable and impromptu questions come from the built-in bank.
   - `SPEAKUP_DATA_DIR`: the data directory above, unless the launchd template sets it.
   - `SPEAKUP_STT_ENGINE`, `SPEAKUP_COACH_MODEL`, `SPEAKUP_PORT`: optional; defaults are in [Configuration](architecture.md#configuration).
4. Try it in a terminal with `uv run speakup-server`. It listens on `127.0.0.1` only. Check it with `curl -H "Authorization: Bearer <token>" http://127.0.0.1:8765/v1/health`.

## Keep it running with launchd

The template is `server/deploy/com.speakup.server.plist.template`.

1. Copy it to `~/Library/LaunchAgents/com.speakup.server.plist` and replace `__REPO_DIR__` (the serving checkout) and `__HOME__` (your home directory).
2. Run `plutil -lint ~/Library/LaunchAgents/com.speakup.server.plist`.
3. Start it with `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.speakup.server.plist`.

The job runs `server/.venv/bin/speakup-server` directly, puts Homebrew on `PATH` for ffmpeg, restarts after a crash, and waits 10 seconds between restarts.

A LaunchAgent runs only while its user is logged in to the desktop.
A Mac mini that reboots therefore needs automatic login (System Settings, Users & Groups), which FileVault blocks.
Without automatic login, turn the job into a LaunchDaemon: put the plist in `/Library/LaunchDaemons`, owned by root with mode 644, and add a `UserName` key with your user name.

### Logs, restart, stop

- Logs: `~/Library/Logs/speakup-server.log`. The server logs stage failures, retries and any stage that runs longer than 10 minutes. It never logs the token or keys.
- Restart: `launchctl kickstart -k gui/$(id -u)/com.speakup.server`.
- Stop: `launchctl bootout gui/$(id -u)/com.speakup.server`.

A restart is safe at any time.
The worker resumes every unfinished take from the start of its current stage.
A stage that was running when the process died is counted, and after three such interruptions the take stops being retried: it fails, or for coaching it ends with `coaching_status: "failed"`.
At startup the server also deletes staged uploads in `tmp/`, which were never acknowledged to the phone.
Take directories that have no database row, the leftovers of a crash during an upload, are moved to `orphans/` rather than deleted, so restoring an older database backup cannot destroy newer recordings.
Check `orphans/` after restoring a backup, and delete what you do not need.
It skips that cleanup when it has just created a new database, because a lost database file must not cost the recordings beside it.

## Publish to the tailnet

The server never listens on a public address.
Publish it with HTTPS to your tailnet only:

```text
tailscale serve --bg --https=443 http://127.0.0.1:8765
tailscale serve status
```

The app's server address is then `https://<machine>.<tailnet>.ts.net`, and the app sends the token as a bearer header.
Use the port from `SPEAKUP_PORT` if you changed it.
If 8765 is taken by another app, set another port in `SPEAKUP_PORT` and use it as the serve target.
With the standalone Tailscale app on macOS, the CLI is `/Applications/Tailscale.app/Contents/MacOS/Tailscale`.
To stop publishing, run `tailscale serve --https=443 off`.

## Backups

Everything is under `SPEAKUP_DATA_DIR`: `speakup.db` (WAL mode), `takes/<id>/` and `profile.md`.
Stop the server or use `sqlite3 speakup.db ".backup copy.db"` before copying the database, so the copy is consistent.
