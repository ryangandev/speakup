"""Crash leftovers, durable writes, a worker that survives, token usage and coaching wiring."""

from __future__ import annotations

import logging
import sqlite3
import time
from types import SimpleNamespace

import pytest
from support import PROMPT_ID, TAKE1_ID, build_env, wav_bytes

from speakup import config
from speakup.api import defaults, routes
from speakup.coaching import claude
from speakup.store import Store, db, durable

ORPHAN_ID = "9d3e5f70-1a2b-4c3d-8e4f-506172839405"


# -- startup sweep ----------------------------------------------------------------------------


def test_startup_empties_tmp_and_removes_take_directories_without_a_row(env):
    env.seed()
    env.upload(TAKE1_ID, attempt=1)
    # What a crash leaves: a staged upload, and audio moved into place before the insert.
    (env.data_dir / "tmp" / "upload-123.wav").write_bytes(wav_bytes())
    orphan = env.data_dir / "takes" / ORPHAN_ID
    orphan.mkdir()
    (orphan / "original.wav").write_bytes(wav_bytes())

    again = Store(env.data_dir)
    assert sorted(again.swept) == [f"takes/{ORPHAN_ID}", "tmp/upload-123.wav"]
    assert list((env.data_dir / "tmp").iterdir()) == []
    assert not orphan.exists()
    # A take with a row keeps its audio.
    assert (env.data_dir / "takes" / TAKE1_ID / "original.wav").is_file()
    assert again.get_take(TAKE1_ID) is not None


def test_a_fresh_database_never_sweeps_recordings_beside_it(tmp_path):
    data = tmp_path / "data"
    kept = data / "takes" / ORPHAN_ID
    kept.mkdir(parents=True)
    (kept / "original.wav").write_bytes(wav_bytes())
    store = Store(data)
    assert store.swept == []
    assert (kept / "original.wav").is_file()  # the database may simply have been lost


# -- the insert path --------------------------------------------------------------------------


class FailingCommit:
    """A connection whose COMMIT fails, as a full disk would."""

    def __init__(self, conn):
        self._conn = conn

    def execute(self, sql, *args):
        if sql == "COMMIT":
            raise sqlite3.OperationalError("disk I/O error")
        return self._conn.execute(sql, *args)

    def close(self):
        self._conn.close()


def test_a_failed_commit_removes_the_moved_audio(env):
    env.seed()
    store = env.store
    real_connect = store._connect
    store._connect = lambda: FailingCommit(real_connect())
    staged = store.tmp_dir / "staged.wav"
    staged.write_bytes(wav_bytes())
    with pytest.raises(sqlite3.OperationalError):
        store.create_take(
            id=TAKE1_ID,
            prompt_id=PROMPT_ID,
            attempt=1,
            recorded_at="2026-11-09T08:15:01.000Z",
            duration_s=1.0,
            mic_route=None,
            audio_sha256="0" * 64,
            staged_audio=staged,
        )
    store._connect = real_connect
    assert not (env.data_dir / "takes" / TAKE1_ID).exists()
    assert store.get_take(TAKE1_ID) is None


# -- fsync ------------------------------------------------------------------------------------


def test_fsync_uses_full_fsync_where_the_platform_has_it(monkeypatch):
    calls = []
    monkeypatch.setattr(durable.fcntl, "F_FULLFSYNC", 51, raising=False)
    monkeypatch.setattr(durable.fcntl, "fcntl", lambda fd, op: calls.append(("fcntl", op)))
    monkeypatch.setattr(durable.os, "fsync", lambda fd: calls.append(("fsync", fd)))
    durable.fsync_fd(3)
    assert calls == [("fcntl", 51)]


def test_fsync_falls_back_to_a_plain_fsync(monkeypatch):
    calls = []

    def refuse(fd, op):
        raise OSError("not supported here")

    monkeypatch.setattr(durable.fcntl, "F_FULLFSYNC", 51, raising=False)
    monkeypatch.setattr(durable.fcntl, "fcntl", refuse)
    monkeypatch.setattr(durable.os, "fsync", lambda fd: calls.append(fd))
    durable.fsync_fd(3)
    assert calls == [3]
    monkeypatch.delattr(durable.fcntl, "F_FULLFSYNC")
    durable.fsync_fd(4)
    assert calls == [3, 4]


def test_an_upload_flushes_the_file_and_the_directories_before_answering(env, monkeypatch):
    env.seed()
    flushed = []
    monkeypatch.setattr(routes, "fsync_fd", lambda fd: flushed.append(fd))
    monkeypatch.setattr(db, "fsync_dir", lambda path: flushed.append(path))
    assert env.upload(TAKE1_ID, attempt=1).status_code == 201
    take_dir = env.data_dir / "takes" / TAKE1_ID
    assert isinstance(flushed[0], int)  # the staged file, before it is moved
    assert flushed[1:] == [take_dir, take_dir.parent]


def test_the_database_syncs_fully(env):
    with env.store._read() as conn:
        assert conn.execute("PRAGMA synchronous").fetchone()[0] == 2  # FULL
        assert conn.execute("PRAGMA fullfsync").fetchone()[0] == 1


# -- the worker survives ----------------------------------------------------------------------


def test_the_worker_thread_survives_a_failing_resume(env, caplog):
    env.seed()
    env.upload(TAKE1_ID, attempt=1)
    env.worker._startup_retry_seconds = 0.01
    real = env.worker.resume
    state = {"calls": 0}

    def flaky():
        state["calls"] += 1
        if state["calls"] < 3:
            raise sqlite3.OperationalError("database is locked")
        real()

    env.worker.resume = flaky
    with caplog.at_level(logging.ERROR):
        env.worker.start()
        for _ in range(300):
            if env.take(TAKE1_ID)["status"] == "done":
                break
            time.sleep(0.02)
        env.worker.stop()
    assert env.take(TAKE1_ID)["status"] == "done"
    assert state["calls"] == 3
    assert "could not start" in caplog.text


def test_a_stage_that_runs_long_is_logged(tmp_path, caplog):
    env = build_env(tmp_path / "data")
    env.worker._slow_stage_seconds = 0.05
    env.seed()
    env.upload(TAKE1_ID, attempt=1)
    real = env.engine.transcribe

    def slow(*args):
        time.sleep(0.2)
        return real(*args)

    env.engine.transcribe = slow
    with caplog.at_level(logging.WARNING):
        env.run()
    assert "has been in transcribing for over" in caplog.text
    assert "has been in analyzing" not in caplog.text


# -- token usage ------------------------------------------------------------------------------


def usage_json(env, take_id):
    with env.store._read() as conn:
        rows = conn.execute(
            "SELECT usage_json FROM coaching_reports WHERE take_id = ?", (take_id,)
        ).fetchall()
    return [r["usage_json"] for r in rows]


def test_coaching_usage_is_stored_when_the_coach_reports_it(env):
    env.seed()
    env.upload(TAKE1_ID, attempt=1)
    env.run()
    stored = usage_json(env, TAKE1_ID)
    assert len(stored) == 1
    assert '"input_tokens": 1200' in stored[0]


def test_a_coach_without_usage_still_works(env):
    env.seed()
    coach = env.coach
    env.worker.coach = SimpleNamespace(
        coaching_info=coach.coaching_info, coach_take=coach.coach_take
    )
    env.upload(TAKE1_ID, attempt=1)
    env.run()
    assert env.take(TAKE1_ID)["coaching_status"] == "done"
    assert usage_json(env, TAKE1_ID) == [None]


def test_the_real_coaching_module_is_wrapped_to_report_usage():
    coach = defaults.load_coach()
    assert callable(coach.coach_take_with_usage)
    assert coach.CoachingFailed.__name__ == "CoachingFailed"
    assert callable(coach.coaching_info)


# -- coaching wiring --------------------------------------------------------------------------


def test_the_anthropic_client_has_a_timeout_and_keeps_its_retries(monkeypatch):
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test-not-real")
    monkeypatch.setattr(claude, "_clients", {})
    api = claude.client()
    assert api.timeout == 120
    assert api.max_retries == 2


def test_coaching_reads_the_data_dir_from_config(monkeypatch, tmp_path):
    assert claude.data_dir() == config.data_dir()
    monkeypatch.setenv("SPEAKUP_DATA_DIR", str(tmp_path))
    assert claude.data_dir() == tmp_path
    assert config.server_settings().data_dir == tmp_path
