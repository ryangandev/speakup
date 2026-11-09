"""SQLite store: sessions, prompts, takes and the stage outputs, plus the audio file layout.

Every method opens its own short-lived connection, so the API's threads and the pipeline worker
never share one. Writers take the database lock up front (BEGIN IMMEDIATE) and wait up to five
seconds for it. Rows come back as plain dicts; JSON documents are stored as text and parsed by
the caller.
"""

from __future__ import annotations

import contextlib
import json
import logging
import os
import shutil
import sqlite3
import uuid
from collections.abc import Callable, Iterator
from pathlib import Path
from typing import Any

from speakup.store.clock import now_ts
from speakup.store.durable import fsync_dir
from speakup.store.migrations import MIGRATIONS

log = logging.getLogger(__name__)

TERMINAL_STATUSES = ("done", "failed")
UNFINISHED_STATUSES = ("uploaded", "transcribing", "analyzing", "coaching")
REPROCESS_STAGES = ("transcribing", "analyzing", "coaching")

Row = dict[str, Any]


class Conflict(Exception):
    """A create reused an id (or an attempt number) with different content."""


class InvalidState(Exception):
    """The requested change is not allowed in the take's current state."""


def _new_id() -> str:
    return str(uuid.uuid4())


# A take plus what lists need: its session, and the pieces of the summary, pulled out of the
# stored JSON by SQLite so a session list does not parse whole analyses.
_TAKE_SELECT = """
SELECT t.*, p.session_id AS session_id,
  CASE WHEN t.status = 'done'
    THEN json_extract(a.final_json, '$.metrics.fillers.per_100_words') END AS s_fillers,
  CASE WHEN t.status = 'done'
    THEN json_extract(a.final_json, '$.metrics.blocks.count') END AS s_blocks,
  CASE WHEN t.status = 'done'
    THEN json_extract(a.final_json, '$.metrics.restarts') END AS s_restarts,
  CASE WHEN t.status = 'done'
    THEN json_extract(a.final_json, '$.metrics.pace.wpm_voiced') END AS s_wpm,
  CASE WHEN t.status = 'done' AND c.id IS NOT NULL
    THEN json_extract(c.json, '$.verdict') END AS s_verdict,
  CASE WHEN t.status = 'done' AND c.id IS NOT NULL
    THEN (SELECT json_group_array(json_extract(f.value, '$.title'))
          FROM json_each(c.json, '$.focus') AS f) END AS s_focus_titles
FROM takes t
JOIN prompts p ON p.id = t.prompt_id
LEFT JOIN analyses a ON a.id = t.analysis_id
LEFT JOIN coaching_reports c ON c.id = t.coaching_id
"""


class Store:
    def __init__(self, data_dir: Path, clock: Callable[[], str] = now_ts) -> None:
        self.data_dir = Path(data_dir)
        self.clock = clock
        self.db_path = self.data_dir / "speakup.db"
        self.data_dir.mkdir(parents=True, exist_ok=True)
        (self.data_dir / "takes").mkdir(exist_ok=True)
        self.tmp_dir.mkdir(exist_ok=True)
        created = self._migrate()
        self.swept: list[str] = []
        # Never sweep next to a database that was just created: if the database file was lost,
        # the recordings beside it are all that is left of those takes.
        if not created:
            self.swept = self._sweep()

    # -- layout ---------------------------------------------------------------------------

    @property
    def tmp_dir(self) -> Path:
        """Where uploads are staged; on the same volume as `takes/` so a move is atomic."""
        return self.data_dir / "tmp"

    def take_dir(self, take_id: str) -> Path:
        return self.data_dir / "takes" / take_id

    def original_path(self, take_id: str) -> Path:
        return self.take_dir(take_id) / "original.wav"

    def audio16k_path(self, take_id: str) -> Path:
        return self.take_dir(take_id) / "audio16k.wav"

    # -- connections ----------------------------------------------------------------------

    def _connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.db_path, timeout=5, isolation_level=None)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA foreign_keys = ON")
        conn.execute("PRAGMA busy_timeout = 5000")
        # A 201 for an upload also means its row survives a power cut.
        conn.execute("PRAGMA synchronous = FULL")
        conn.execute("PRAGMA fullfsync = ON")
        return conn

    @contextlib.contextmanager
    def _read(self) -> Iterator[sqlite3.Connection]:
        conn = self._connect()
        try:
            yield conn
        finally:
            conn.close()

    @contextlib.contextmanager
    def _write(self, undo: list[Callable[[], None]] | None = None) -> Iterator[sqlite3.Connection]:
        """A transaction. If the body or the COMMIT fails, roll back and run the `undo` steps
        (the caller appends them as it makes changes outside the database)."""
        conn = self._connect()
        try:
            conn.execute("BEGIN IMMEDIATE")
            try:
                yield conn
                conn.execute("COMMIT")
            except BaseException:
                with contextlib.suppress(sqlite3.Error):
                    conn.execute("ROLLBACK")
                for step in reversed(undo or []):
                    step()
                raise
        finally:
            conn.close()

    def _sweep(self) -> list[str]:
        """Remove what a crash can leave behind: staged uploads, and take directories with no
        row (the process died after moving the audio but before the insert committed)."""
        removed: list[str] = []
        for leftover in self.tmp_dir.iterdir():
            if leftover.is_dir():
                shutil.rmtree(leftover, ignore_errors=True)
            else:
                leftover.unlink(missing_ok=True)
            removed.append(f"tmp/{leftover.name}")
        with self._read() as conn:
            known = {r["id"] for r in conn.execute("SELECT id FROM takes")}
        for directory in (self.data_dir / "takes").iterdir():
            if directory.name not in known:
                if directory.is_dir():
                    shutil.rmtree(directory)
                else:
                    directory.unlink()
                removed.append(f"takes/{directory.name}")
        if removed:
            log.warning("Removed leftovers of an interrupted run: %s", ", ".join(removed))
        return removed

    def _migrate(self) -> bool:
        """Apply pending migrations; return whether the database was new."""
        conn = sqlite3.connect(self.db_path, timeout=5, isolation_level=None)
        try:
            conn.execute("PRAGMA journal_mode = WAL")
            has_table = conn.execute(
                "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'schema_migrations'"
            ).fetchone()
            current = 0
            if has_table:
                current = conn.execute("SELECT MAX(version) FROM schema_migrations").fetchone()[0]
                current = current or 0
            newest = MIGRATIONS[-1][0]
            if current > newest:
                raise RuntimeError(
                    f"The database is at schema version {current}, newer than this server's "
                    f"{newest}. Run a newer server."
                )
            for version, sql in MIGRATIONS:
                if version <= current:
                    continue
                conn.execute("BEGIN IMMEDIATE")
                try:
                    for statement in _split_statements(sql):
                        conn.execute(statement)
                    conn.execute(
                        "INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)",
                        (version, self.clock()),
                    )
                except BaseException:
                    conn.execute("ROLLBACK")
                    raise
                conn.execute("COMMIT")
            return current == 0
        finally:
            conn.close()

    # -- sessions -------------------------------------------------------------------------

    def create_session(
        self, *, id: str, mode: str, started_at: str, nervousness_before: int | None
    ) -> tuple[Row, bool]:
        """Return (session, created). Raises Conflict when the id exists with another mode or
        start time."""
        with self._write() as conn:
            row = conn.execute("SELECT * FROM sessions WHERE id = ?", (id,)).fetchone()
            if row is not None:
                if row["mode"] == mode and row["started_at"] == started_at:
                    return dict(row), False
                raise Conflict(f"Session {id} already exists with a different mode or start time.")
            now = self.clock()
            conn.execute(
                "INSERT INTO sessions (id, mode, started_at, nervousness_before, created_at,"
                " updated_at) VALUES (?, ?, ?, ?, ?, ?)",
                (id, mode, started_at, nervousness_before, now, now),
            )
            return dict(conn.execute("SELECT * FROM sessions WHERE id = ?", (id,)).fetchone()), True

    def get_session(self, session_id: str) -> Row | None:
        with self._read() as conn:
            row = conn.execute("SELECT * FROM sessions WHERE id = ?", (session_id,)).fetchone()
        return dict(row) if row else None

    def update_session(self, session_id: str, changes: dict[str, Any]) -> Row | None:
        """Set the given columns (ended_at, nervousness_before, nervousness_after)."""
        allowed = {"ended_at", "nervousness_before", "nervousness_after"}
        unknown = set(changes) - allowed
        if unknown:
            raise ValueError(f"Cannot update {sorted(unknown)}")
        with self._write() as conn:
            if (
                conn.execute("SELECT 1 FROM sessions WHERE id = ?", (session_id,)).fetchone()
                is None
            ):
                return None
            assignments = [f"{column} = ?" for column in changes]
            values = [*changes.values(), self.clock(), session_id]
            conn.execute(
                f"UPDATE sessions SET {', '.join([*assignments, 'updated_at = ?'])} WHERE id = ?",
                values,
            )
            return dict(
                conn.execute("SELECT * FROM sessions WHERE id = ?", (session_id,)).fetchone()
            )

    def list_sessions(self, *, before: str, limit: int) -> list[Row]:
        """Sessions started before `before`, newest first."""
        with self._read() as conn:
            rows = conn.execute(
                "SELECT * FROM sessions WHERE started_at < ? ORDER BY started_at DESC, rowid DESC"
                " LIMIT ?",
                (before, limit),
            ).fetchall()
        return [dict(r) for r in rows]

    def prompt_summaries(self, session_ids: list[str]) -> dict[str, list[Row]]:
        """Per session, its prompts in creation order with their take counts."""
        result: dict[str, list[Row]] = {sid: [] for sid in session_ids}
        if not session_ids:
            return result
        marks = ", ".join("?" for _ in session_ids)
        with self._read() as conn:
            rows = conn.execute(
                f"SELECT p.session_id, p.id, p.kind, p.text,"
                f" (SELECT COUNT(*) FROM takes t WHERE t.prompt_id = p.id) AS take_count"
                f" FROM prompts p WHERE p.session_id IN ({marks})"
                f" ORDER BY p.created_at, p.rowid",
                session_ids,
            ).fetchall()
        for row in rows:
            result[row["session_id"]].append(dict(row))
        return result

    # -- prompts --------------------------------------------------------------------------

    _PROMPT_FIELDS = (
        "session_id",
        "kind",
        "text",
        "notes",
        "category",
        "target_seconds",
        "question_source",
    )

    def create_prompt(self, *, id: str, **fields: Any) -> tuple[Row, bool]:
        """Return (prompt, created). Raises Conflict when the id exists with other content and
        LookupError("session_id") when the session is unknown."""
        values = [fields[name] for name in self._PROMPT_FIELDS]
        with self._write() as conn:
            row = conn.execute("SELECT * FROM prompts WHERE id = ?", (id,)).fetchone()
            if row is not None:
                if all(row[name] == fields[name] for name in self._PROMPT_FIELDS):
                    return dict(row), False
                raise Conflict(f"Prompt {id} already exists with different content.")
            session = conn.execute(
                "SELECT 1 FROM sessions WHERE id = ?", (fields["session_id"],)
            ).fetchone()
            if session is None:
                raise LookupError("session_id")
            conn.execute(
                f"INSERT INTO prompts (id, {', '.join(self._PROMPT_FIELDS)}, created_at)"
                f" VALUES (?, {', '.join('?' for _ in self._PROMPT_FIELDS)}, ?)",
                (id, *values, self.clock()),
            )
            return dict(conn.execute("SELECT * FROM prompts WHERE id = ?", (id,)).fetchone()), True

    def get_prompt(self, prompt_id: str) -> Row | None:
        with self._read() as conn:
            row = conn.execute("SELECT * FROM prompts WHERE id = ?", (prompt_id,)).fetchone()
        return dict(row) if row else None

    def list_prompts(self, session_id: str) -> list[Row]:
        with self._read() as conn:
            rows = conn.execute(
                "SELECT * FROM prompts WHERE session_id = ? ORDER BY created_at, rowid",
                (session_id,),
            ).fetchall()
        return [dict(r) for r in rows]

    def recent_impromptu_texts(self, limit: int) -> list[str]:
        with self._read() as conn:
            rows = conn.execute(
                "SELECT text FROM prompts WHERE kind = 'impromptu'"
                " ORDER BY created_at DESC, rowid DESC LIMIT ?",
                (limit,),
            ).fetchall()
        return [r["text"] for r in rows]

    # -- takes: API side ------------------------------------------------------------------

    def get_take(self, take_id: str) -> Row | None:
        with self._read() as conn:
            row = conn.execute(f"{_TAKE_SELECT} WHERE t.id = ?", (take_id,)).fetchone()
        return dict(row) if row else None

    def list_takes(self, prompt_ids: list[str]) -> dict[str, list[Row]]:
        """Per prompt, its takes by attempt."""
        result: dict[str, list[Row]] = {pid: [] for pid in prompt_ids}
        if not prompt_ids:
            return result
        marks = ", ".join("?" for _ in prompt_ids)
        with self._read() as conn:
            rows = conn.execute(
                f"{_TAKE_SELECT} WHERE t.prompt_id IN ({marks}) ORDER BY t.attempt", prompt_ids
            ).fetchall()
        for row in rows:
            result[row["prompt_id"]].append(dict(row))
        return result

    def queue_length(self) -> int:
        marks = ", ".join("?" for _ in UNFINISHED_STATUSES)
        with self._read() as conn:
            return conn.execute(
                f"SELECT COUNT(*) FROM takes WHERE status IN ({marks})", UNFINISHED_STATUSES
            ).fetchone()[0]

    def create_take(
        self,
        *,
        id: str,
        prompt_id: str,
        attempt: int,
        recorded_at: str,
        duration_s: float,
        mic_route: str | None,
        audio_sha256: str,
        staged_audio: Path,
    ) -> tuple[Row, bool]:
        """Move the staged audio into place and insert the take, in one step.

        Return (take, created). A repeat of an upload with the same id and hash returns the
        existing take and leaves `staged_audio` for the caller to delete. Raises Conflict when
        the id exists with a different hash or (prompt_id, attempt) is taken, and
        LookupError("prompt_id") for an unknown prompt.
        """
        undo: list[Callable[[], None]] = []
        with self._write(undo) as conn:
            existing = conn.execute("SELECT * FROM takes WHERE id = ?", (id,)).fetchone()
            if existing is not None:
                if existing["audio_sha256"] == audio_sha256:
                    return self._take_in(conn, id), False
                raise Conflict(f"Take {id} already exists with different audio.")
            if conn.execute("SELECT 1 FROM prompts WHERE id = ?", (prompt_id,)).fetchone() is None:
                raise LookupError("prompt_id")
            if conn.execute(
                "SELECT 1 FROM takes WHERE prompt_id = ? AND attempt = ?", (prompt_id, attempt)
            ).fetchone():
                raise Conflict(f"Attempt {attempt} of this prompt already has a take.")
            guess = conn.execute(
                "SELECT id FROM takes WHERE prompt_id = ? AND attempt = ?", (prompt_id, attempt - 1)
            ).fetchone()
            now = self.clock()
            destination = self.original_path(id)
            destination.parent.mkdir(parents=True, exist_ok=True)
            os.replace(staged_audio, destination)
            # Whatever fails from here on, including the COMMIT, must not leave audio without a row.
            undo.append(lambda: _remove_take_files(destination))
            fsync_dir(destination.parent)
            fsync_dir(destination.parent.parent)
            conn.execute(
                "INSERT INTO takes (id, prompt_id, attempt, recorded_at, duration_s, mic_route,"
                " audio_sha256, status, status_changed_at, coaching_status, previous_take_id,"
                " created_at, updated_at)"
                " VALUES (?, ?, ?, ?, ?, ?, ?, 'uploaded', ?, 'pending', ?, ?, ?)",
                (
                    id,
                    prompt_id,
                    attempt,
                    recorded_at,
                    duration_s,
                    mic_route,
                    audio_sha256,
                    now,
                    guess["id"] if guess else None,
                    now,
                    now,
                ),
            )
            return self._take_in(conn, id), True

    @staticmethod
    def _take_in(conn: sqlite3.Connection, take_id: str) -> Row:
        return dict(conn.execute(f"{_TAKE_SELECT} WHERE t.id = ?", (take_id,)).fetchone())

    def reprocess(self, take_id: str, from_stage: str) -> Row | None:
        """Send a done or failed take back to `from_stage`. Returns None for an unknown take and
        raises InvalidState when the take is still processing or lacks the earlier outputs."""
        if from_stage not in REPROCESS_STAGES:
            raise ValueError(f"Unknown stage {from_stage}")
        with self._write() as conn:
            row = conn.execute("SELECT * FROM takes WHERE id = ?", (take_id,)).fetchone()
            if row is None:
                return None
            if row["status"] not in TERMINAL_STATUSES:
                raise InvalidState(f"The take is still {row['status']}.")
            if from_stage != "transcribing" and row["transcript_id"] is None:
                raise InvalidState("The take has no transcript yet; reprocess from transcribing.")
            if from_stage == "coaching" and row["analysis_id"] is None:
                raise InvalidState("The take has no analysis yet; reprocess from analyzing.")
            cleared = {
                "transcribing": ("transcript_id", "analysis_id", "coaching_id"),
                "analyzing": ("analysis_id", "coaching_id"),
                "coaching": ("coaching_id",),
            }[from_stage]
            now = self.clock()
            clear = ", ".join(f"{column} = NULL" for column in cleared)
            conn.execute(
                f"UPDATE takes SET status = ?, status_changed_at = ?, coaching_status = 'pending',"
                f" error_code = NULL, error_message = NULL, stage_failures = 0,"
                f" stage_started_at = NULL, updated_at = ?, {clear} WHERE id = ?",
                (from_stage, now, now, take_id),
            )
            return self._take_in(conn, take_id)

    # -- takes: worker side ---------------------------------------------------------------

    def next_unfinished(self) -> Row | None:
        """The oldest recording that is not done or failed."""
        marks = ", ".join("?" for _ in UNFINISHED_STATUSES)
        with self._read() as conn:
            row = conn.execute(
                f"{_TAKE_SELECT} WHERE t.status IN ({marks})"
                f" ORDER BY t.recorded_at, t.created_at, t.rowid LIMIT 1",
                UNFINISHED_STATUSES,
            ).fetchone()
        return dict(row) if row else None

    def interrupted_takes(self) -> list[Row]:
        """Takes whose stage the worker had in hand when the process last stopped.

        A take that was only waiting in a stage (for example after a reprocess) is not listed.
        """
        with self._read() as conn:
            rows = conn.execute(
                "SELECT id, status FROM takes WHERE stage_started_at IS NOT NULL"
                " AND status IN ('transcribing', 'analyzing', 'coaching')"
            ).fetchall()
        return [dict(r) for r in rows]

    def begin_stage(self, take_id: str, status: str) -> None:
        """Set the status before a stage runs. Entering a new stage resets its failure count."""
        now = self.clock()
        with self._write() as conn:
            conn.execute(
                "UPDATE takes SET"
                " status_changed_at = CASE WHEN status != ?1 THEN ?2 ELSE status_changed_at END,"
                " stage_failures = CASE WHEN status != ?1 THEN 0 ELSE stage_failures END,"
                " status = ?1, stage_started_at = ?2, error_code = NULL, error_message = NULL,"
                " updated_at = ?2"
                " WHERE id = ?3",
                (status, now, take_id),
            )

    def bump_stage_failures(self, take_id: str) -> int:
        """Count one more interruption of the take's current stage; return the new count.

        The running marker is cleared, so the stage is only counted again if the worker starts
        it again and the process dies again.
        """
        with self._write() as conn:
            conn.execute(
                "UPDATE takes SET stage_failures = stage_failures + 1, stage_started_at = NULL"
                " WHERE id = ?",
                (take_id,),
            )
            return conn.execute(
                "SELECT stage_failures FROM takes WHERE id = ?", (take_id,)
            ).fetchone()[0]

    def fail_take(self, take_id: str, code: str, message: str) -> None:
        now = self.clock()
        with self._write() as conn:
            conn.execute(
                "UPDATE takes SET status = 'failed', status_changed_at = ?, error_code = ?,"
                " error_message = ?, stage_failures = 0, stage_started_at = NULL, updated_at = ?"
                " WHERE id = ?",
                (now, code, message, now, take_id),
            )

    def complete_take(self, take_id: str) -> None:
        now = self.clock()
        with self._write() as conn:
            conn.execute(
                "UPDATE takes SET status = 'done', status_changed_at = ?, error_code = NULL,"
                " error_message = NULL, stage_failures = 0, stage_started_at = NULL,"
                " updated_at = ? WHERE id = ?",
                (now, now, take_id),
            )

    def set_coaching_status(self, take_id: str, coaching_status: str) -> None:
        with self._write() as conn:
            conn.execute(
                "UPDATE takes SET coaching_status = ?, updated_at = ? WHERE id = ?",
                (coaching_status, self.clock(), take_id),
            )

    def resolve_previous_take(self, take_id: str) -> Row | None:
        """Set and return the previous take: the highest earlier attempt of the same prompt that
        is done. Returns None (and clears the field) when there is none."""
        with self._write() as conn:
            current = conn.execute(
                "SELECT prompt_id, attempt FROM takes WHERE id = ?", (take_id,)
            ).fetchone()
            previous = conn.execute(
                f"{_TAKE_SELECT} WHERE t.prompt_id = ? AND t.attempt < ? AND t.status = 'done'"
                f" ORDER BY t.attempt DESC LIMIT 1",
                (current["prompt_id"], current["attempt"]),
            ).fetchone()
            conn.execute(
                "UPDATE takes SET previous_take_id = ?, updated_at = ? WHERE id = ?",
                (previous["id"] if previous else None, self.clock(), take_id),
            )
            return dict(previous) if previous else None

    def save_transcript(self, take_id: str, engine: str, transcript_json: str) -> str:
        transcript_id = _new_id()
        with self._write() as conn:
            conn.execute(
                "INSERT INTO transcripts (id, take_id, engine, created_at, json)"
                " VALUES (?, ?, ?, ?, ?)",
                (transcript_id, take_id, engine, self.clock(), transcript_json),
            )
            conn.execute(
                "UPDATE takes SET transcript_id = ?, updated_at = ? WHERE id = ?",
                (transcript_id, self.clock(), take_id),
            )
        return transcript_id

    def save_analysis(
        self,
        take_id: str,
        transcript_id: str,
        stage: dict[str, Any],
        final: dict[str, Any],
    ) -> str:
        analysis_id = _new_id()
        with self._write() as conn:
            conn.execute(
                "INSERT INTO analyses (id, take_id, transcript_id, schema_version, created_at,"
                " stage_json, final_json) VALUES (?, ?, ?, ?, ?, ?, ?)",
                (
                    analysis_id,
                    take_id,
                    transcript_id,
                    str(stage.get("schema_version", "")),
                    self.clock(),
                    json.dumps(stage, ensure_ascii=False),
                    json.dumps(final, ensure_ascii=False),
                ),
            )
            conn.execute(
                "UPDATE takes SET analysis_id = ?, coaching_id = NULL, updated_at = ? WHERE id = ?",
                (analysis_id, self.clock(), take_id),
            )
        return analysis_id

    def set_final_analysis(self, analysis_id: str, final: dict[str, Any]) -> None:
        with self._write() as conn:
            conn.execute(
                "UPDATE analyses SET final_json = ? WHERE id = ?",
                (json.dumps(final, ensure_ascii=False), analysis_id),
            )

    def save_coaching(
        self,
        take_id: str,
        analysis_id: str,
        report: dict[str, Any],
        final: dict[str, Any],
        usage: Any = None,
    ) -> str:
        """Store the report, rewrite the analysis's final document, and mark coaching done,
        together."""
        coaching_id = _new_id()
        now = self.clock()
        with self._write() as conn:
            conn.execute(
                "INSERT INTO coaching_reports (id, take_id, analysis_id, model, rubric_version,"
                " prompt_version, created_at, json, usage_json) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (
                    coaching_id,
                    take_id,
                    analysis_id,
                    str(report.get("model", "")),
                    str(report.get("rubric_version", "")),
                    str(report.get("prompt_version", "")),
                    now,
                    json.dumps(report, ensure_ascii=False),
                    json.dumps(usage) if usage is not None else None,
                ),
            )
            conn.execute(
                "UPDATE analyses SET final_json = ? WHERE id = ?",
                (json.dumps(final, ensure_ascii=False), analysis_id),
            )
            conn.execute(
                "UPDATE takes SET coaching_id = ?, coaching_status = 'done', updated_at = ?"
                " WHERE id = ?",
                (coaching_id, now, take_id),
            )
        return coaching_id

    # -- stage outputs --------------------------------------------------------------------

    def transcript_json(self, transcript_id: str | None) -> str | None:
        if transcript_id is None:
            return None
        with self._read() as conn:
            row = conn.execute(
                "SELECT json FROM transcripts WHERE id = ?", (transcript_id,)
            ).fetchone()
        return row["json"] if row else None

    def analysis_docs(
        self, analysis_id: str | None
    ) -> tuple[dict[str, Any], dict[str, Any]] | None:
        """(stage, final) analysis documents."""
        if analysis_id is None:
            return None
        with self._read() as conn:
            row = conn.execute(
                "SELECT stage_json, final_json FROM analyses WHERE id = ?", (analysis_id,)
            ).fetchone()
        if row is None:
            return None
        return json.loads(row["stage_json"]), json.loads(row["final_json"])

    def coaching_doc(self, coaching_id: str | None) -> dict[str, Any] | None:
        if coaching_id is None:
            return None
        with self._read() as conn:
            row = conn.execute(
                "SELECT json FROM coaching_reports WHERE id = ?", (coaching_id,)
            ).fetchone()
        return json.loads(row["json"]) if row else None


def _remove_take_files(original: Path) -> None:
    original.unlink(missing_ok=True)
    with contextlib.suppress(OSError):
        original.parent.rmdir()


def _split_statements(sql: str) -> list[str]:
    """Split a migration script into statements. Migrations here hold no semicolons inside
    strings or triggers, so a plain split after comment stripping is enough."""
    lines = [line.split("--", 1)[0] for line in sql.splitlines()]
    return [s.strip() for s in "\n".join(lines).split(";") if s.strip()]
