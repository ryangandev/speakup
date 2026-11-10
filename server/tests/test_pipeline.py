"""Stage failures, retries, coaching outcomes, reprocessing and restart recovery."""

from __future__ import annotations

import sqlite3
import time
from contextlib import closing

import httpx
import pytest
from fastapi.testclient import TestClient
from support import (
    COMPARISON_EXAMPLE,
    TAKE1_ID,
    TAKE2_ID,
    TOKEN,
    FakeAnalyzer,
    FakeClock,
    FakeCoach,
    FakeEngine,
    copy_convert,
)

from speakup.api import create_app
from speakup.pipeline import Worker
from speakup.pipeline.worker import MAX_STAGE_INTERRUPTIONS
from speakup.store import Store

TAKE3_ID = "5a9c2d7e-3b1f-4a86-9d04-7e6f8a1b2c3d"


def reprocess(env, take_id, stage):
    return env.client.post(f"/v1/takes/{take_id}/reprocess", json={"from_stage": stage})


# -- failures that fail the take --------------------------------------------------------------


def test_fewer_than_five_words_fails_with_no_speech(env):
    env.seed()
    env.engine.words = 3
    env.upload(TAKE1_ID, attempt=1)
    env.run()
    take = env.take(TAKE1_ID)
    assert take["status"] == "failed"
    assert take["error"] == {"code": "no_speech", "message": "Fewer than 5 words were transcribed."}
    assert take["coaching_status"] == "pending"
    assert take["summary"] is None
    assert env.coach.requests == []


def test_undecodable_audio_fails_with_audio_invalid(env):
    env.seed()

    def broken(src, dst):
        raise RuntimeError("ffmpeg said no")

    env.worker._convert = broken
    env.upload(TAKE1_ID, attempt=1)
    env.run()
    take = env.take(TAKE1_ID)
    assert take["status"] == "failed"
    assert take["error"]["code"] == "audio_invalid"
    assert env.engine.calls == []


def test_a_local_engine_error_is_not_retried(env):
    env.seed()
    env.engine.errors = [RuntimeError("model blew up")]
    env.upload(TAKE1_ID, attempt=1)
    env.run()
    take = env.take(TAKE1_ID)
    assert take["status"] == "failed"
    assert take["error"] == {"code": "stt_failed", "message": "Speech to text failed."}
    assert len(env.engine.calls) == 1


def test_a_cloud_engine_error_is_retried_twice(env):
    env.seed()
    request = httpx.Request("POST", "https://stt.example/v1")
    env.engine.errors = [
        httpx.ConnectError("down", request=request),
        httpx.HTTPStatusError("busy", request=request, response=httpx.Response(503)),
    ]
    env.upload(TAKE1_ID, attempt=1)
    env.run()
    assert env.take(TAKE1_ID)["status"] == "done"
    assert len(env.engine.calls) == 3


def test_a_cloud_engine_that_keeps_failing_fails_the_take(env):
    env.seed()
    request = httpx.Request("POST", "https://stt.example/v1")
    env.engine.errors = [httpx.ConnectError("down", request=request) for _ in range(5)]
    env.upload(TAKE1_ID, attempt=1)
    env.run()
    take = env.take(TAKE1_ID)
    assert take["error"]["code"] == "stt_failed"
    assert len(env.engine.calls) == 3  # the first try and two retries


def test_a_client_error_from_a_cloud_engine_is_not_retried(env):
    env.seed()
    request = httpx.Request("POST", "https://stt.example/v1")
    env.engine.errors = [
        httpx.HTTPStatusError("bad key", request=request, response=httpx.Response(401))
    ]
    env.upload(TAKE1_ID, attempt=1)
    env.run()
    assert env.take(TAKE1_ID)["error"]["code"] == "stt_failed"
    assert len(env.engine.calls) == 1


def test_an_analysis_bug_fails_with_analysis_failed_and_is_not_retried(env):
    env.seed()
    env.analyzer.error = ValueError("bug")
    env.upload(TAKE1_ID, attempt=1)
    env.run()
    take = env.take(TAKE1_ID)
    assert take["error"] == {"code": "analysis_failed", "message": "Analysis failed."}
    assert len(env.analyzer.analyze_calls) == 1
    assert len(env.engine.calls) == 1


# -- coaching never fails the take ------------------------------------------------------------


def test_coaching_unavailable_still_finishes_the_take(env):
    env.seed()
    env.coach.available = False
    env.upload(TAKE1_ID, attempt=1)
    env.run()
    take = env.take(TAKE1_ID)
    assert take["status"] == "done"
    assert take["coaching_status"] == "unavailable"
    assert take["summary"]["verdict"] is None
    assert take["summary"]["focus_titles"] == []
    assert take["summary"]["fillers_per_100_words"] == 3.74
    assert env.coach.requests == []

    report = env.client.get(f"/v1/takes/{TAKE1_ID}/report").json()
    assert report["coaching"] is None
    assert report["analysis"]["coaching_applied"] is False
    assert report["take"]["coaching_status"] == "unavailable"
    assert env.client.get("/v1/health").json()["coaching"]["available"] is False


def test_a_retry_without_coaching_gets_a_comparison_of_metrics_only(env):
    env.seed()
    env.coach.available = False
    env.upload_story_takes()
    env.run()
    assert env.take(TAKE2_ID)["previous_take_id"] == TAKE1_ID
    body = env.client.get(f"/v1/takes/{TAKE2_ID}/comparison").json()
    assert body["coaching_status"] == "unavailable"
    assert body["summary"] is None
    assert body["focus_outcomes"] == []
    assert body["dimension_changes"] == []
    assert body["metric_changes"] == COMPARISON_EXAMPLE["metric_changes"]
    assert body["attempt"] == 2
    assert body["previous_attempt"] == 1


def test_get_coaching_after_a_key_is_added(env):
    env.seed()
    env.coach.available = False
    env.upload(TAKE1_ID, attempt=1)
    env.run()
    env.coach.available = True
    response = reprocess(env, TAKE1_ID, "coaching")
    assert response.status_code == 202
    body = response.json()
    assert body["status"] == "coaching"
    assert body["coaching_status"] == "pending"
    assert body["summary"] is None
    assert body["error"] is None
    assert env.client.get("/v1/health").json()["queue_length"] == 1
    env.run()
    take = env.take(TAKE1_ID)
    assert take["status"] == "done"
    assert take["coaching_status"] == "done"
    assert take["summary"]["verdict"]
    report = env.client.get(f"/v1/takes/{TAKE1_ID}/report").json()
    assert report["coaching"]["take_id"] == TAKE1_ID
    assert report["analysis"]["coaching_applied"] is True
    # Transcription and analysis were reused, not rerun.
    assert len(env.engine.calls) == 1
    assert len(env.analyzer.analyze_calls) == 1


def test_coaching_that_fails_leaves_a_done_take(env):
    env.seed()
    env.coach.error = env.coach.CoachingFailed("validation failed twice")
    env.upload(TAKE1_ID, attempt=1)
    env.run()
    take = env.take(TAKE1_ID)
    assert take["status"] == "done"
    assert take["coaching_status"] == "failed"
    assert take["error"] is None
    assert take["summary"]["verdict"] is None
    report = env.client.get(f"/v1/takes/{TAKE1_ID}/report").json()
    assert report["coaching"] is None
    assert report["analysis"]["coaching_applied"] is False


def test_coaching_that_raises_something_unexpected_is_also_a_coaching_failure(env):
    env.seed()
    env.coach.error = RuntimeError("anthropic fell over")
    env.upload(TAKE1_ID, attempt=1)
    env.run()
    take = env.take(TAKE1_ID)
    assert (take["status"], take["coaching_status"]) == ("done", "failed")


def test_coaching_unavailable_raised_during_the_call(env):
    env.seed()
    env.coach.error = env.coach.CoachingUnavailable("no key")
    env.upload(TAKE1_ID, attempt=1)
    env.run()
    take = env.take(TAKE1_ID)
    assert (take["status"], take["coaching_status"]) == ("done", "unavailable")


def test_the_previous_take_skips_attempts_that_are_not_done(env):
    env.seed()
    env.upload(TAKE1_ID, attempt=1, recorded_at="2026-11-09T08:15:00.000Z")
    env.run()
    env.engine.words = 2
    env.upload(TAKE2_ID, attempt=2, recorded_at="2026-11-09T08:16:00.000Z")
    env.run()
    assert env.take(TAKE2_ID)["status"] == "failed"
    env.engine.words = 20
    env.upload(TAKE3_ID, attempt=3, recorded_at="2026-11-09T08:17:00.000Z")
    assert env.take(TAKE3_ID)["previous_take_id"] == TAKE2_ID  # the guess before coaching
    env.run()
    assert env.take(TAKE3_ID)["previous_take_id"] == TAKE1_ID
    assert env.coach.requests[-1]["previous"]["attempt"] == 1
    assert env.client.get(f"/v1/takes/{TAKE3_ID}/comparison").json()["previous_attempt"] == 1


# -- reprocess --------------------------------------------------------------------------------


def count(env, table):
    with closing(sqlite3.connect(env.store.db_path)) as conn:
        return conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]


def test_reprocess_a_failed_take_from_the_start(env):
    env.seed()
    env.engine.words = 2
    env.upload(TAKE1_ID, attempt=1)
    env.run()
    assert env.take(TAKE1_ID)["error"]["code"] == "no_speech"

    env.engine.words = 20
    response = reprocess(env, TAKE1_ID, "transcribing")
    assert response.status_code == 202
    assert response.json()["status"] == "transcribing"
    assert response.json()["error"] is None
    env.run()
    assert env.take(TAKE1_ID)["status"] == "done"
    # Every run of a stage is kept.
    assert count(env, "transcripts") == 2
    assert count(env, "analyses") == 1


def test_reprocess_from_analyzing_reuses_the_transcript(env):
    env.seed()
    env.upload(TAKE1_ID, attempt=1)
    env.run()
    response = reprocess(env, TAKE1_ID, "analyzing")
    assert response.status_code == 202
    assert response.json()["status"] == "analyzing"
    env.run()
    assert env.take(TAKE1_ID)["status"] == "done"
    assert len(env.engine.calls) == 1
    assert len(env.analyzer.analyze_calls) == 2
    assert count(env, "transcripts") == 1
    assert count(env, "analyses") == 2
    assert count(env, "coaching_reports") == 2


def test_reprocess_cannot_skip_a_stage_that_has_no_output(env):
    env.seed()

    def broken(src, dst):
        raise RuntimeError("no")

    env.worker._convert = broken
    env.upload(TAKE1_ID, attempt=1)
    env.run()
    for stage in ("analyzing", "coaching"):
        response = reprocess(env, TAKE1_ID, stage)
        assert response.status_code == 409
        assert response.json()["error"]["code"] == "invalid_state"
    assert env.take(TAKE1_ID)["status"] == "failed"


def test_reprocess_hides_the_old_report_until_the_new_one_exists(env):
    env.seed()
    env.upload(TAKE1_ID, attempt=1)
    env.run()
    reprocess(env, TAKE1_ID, "transcribing")
    response = env.client.get(f"/v1/takes/{TAKE1_ID}/report")
    assert response.status_code == 409
    assert response.json()["error"]["details"] == {"status": "transcribing"}


# -- restart recovery -------------------------------------------------------------------------


class Crash(BaseException):
    """Stands in for the process dying: nothing in the worker catches it."""


def reopen(env, *, clock=None):
    """A second server process on the same data directory."""
    clock = clock or env.clock
    store = Store(env.data_dir, clock=clock)
    engine, analyzer, coach = FakeEngine(store), FakeAnalyzer(store), FakeCoach(store)
    worker = Worker(
        store, engine, analyzer, coach, convert=copy_convert, stt_retry_delays=(0.0, 0.0)
    )
    return store, engine, analyzer, coach, worker


@pytest.mark.parametrize("crash_in", ["transcribing", "analyzing", "coaching"])
def test_restart_resumes_unfinished_takes(env, crash_in):
    env.seed()
    env.upload_story_takes()
    stage_object = {"transcribing": env.engine, "analyzing": env.analyzer, "coaching": env.coach}
    method = {"transcribing": "transcribe", "analyzing": "analyze", "coaching": "coach_take"}
    original = getattr(stage_object[crash_in], method[crash_in])
    state = {"crashed": False}

    def crash_once(*args, **kwargs):
        if not state["crashed"]:
            state["crashed"] = True
            raise Crash
        return original(*args, **kwargs)

    setattr(stage_object[crash_in], method[crash_in], crash_once)
    with pytest.raises(Crash):
        env.run()
    assert env.take(TAKE1_ID)["status"] == crash_in
    assert env.take(TAKE2_ID)["status"] == "uploaded"

    # A new process: its lifespan starts the worker, which resumes both takes.
    store, engine, analyzer, coach, worker = reopen(env)
    app = create_app(store=store, worker=worker, coach=coach, analyzer=analyzer, token=TOKEN)
    with TestClient(app, headers={"Authorization": f"Bearer {TOKEN}"}) as client:
        for _ in range(300):
            states = [client.get(f"/v1/takes/{t}").json()["status"] for t in (TAKE1_ID, TAKE2_ID)]
            if states == ["done", "done"]:
                break
            time.sleep(0.02)
        assert states == ["done", "done"]
        first = client.get(f"/v1/takes/{TAKE1_ID}").json()
        assert first["coaching_status"] == "done"
        # The retry still compares with the take that was interrupted.
        assert client.get(f"/v1/takes/{TAKE2_ID}/comparison").status_code == 200
    assert store.get_take(TAKE1_ID)["stage_failures"] == 0


def test_a_take_that_keeps_killing_the_process_is_given_up_on(env):
    env.seed()
    env.upload(TAKE1_ID, attempt=1)
    for _ in range(MAX_STAGE_INTERRUPTIONS - 1):
        env.store.begin_stage(
            TAKE1_ID, "analyzing"
        )  # the worker picks it up, then the process dies
        env.worker.resume()
        assert env.take(TAKE1_ID)["status"] == "analyzing"
    env.store.begin_stage(TAKE1_ID, "analyzing")
    env.worker.resume()
    take = env.take(TAKE1_ID)
    assert take["status"] == "failed"
    assert take["error"]["code"] == "analysis_failed"


def test_restarts_do_not_blame_a_take_that_never_ran(env):
    # Repro: a reprocessed take waits in its stage; clean restarts must not count against it.
    env.seed()
    env.upload(TAKE1_ID, attempt=1)
    env.run()
    assert reprocess(env, TAKE1_ID, "transcribing").status_code == 202
    for _ in range(MAX_STAGE_INTERRUPTIONS + 2):
        env.worker.resume()
    take = env.take(TAKE1_ID)
    assert take["status"] == "transcribing"
    assert env.store.get_take(TAKE1_ID)["stage_failures"] == 0
    env.run()
    assert env.take(TAKE1_ID)["status"] == "done"


def test_a_stage_is_only_counted_once_per_run(env):
    env.seed()
    env.upload(TAKE1_ID, attempt=1)
    env.store.begin_stage(TAKE1_ID, "analyzing")
    for _ in range(MAX_STAGE_INTERRUPTIONS + 2):
        env.worker.resume()  # restarts without the worker getting to the take in between
    assert env.take(TAKE1_ID)["status"] == "analyzing"
    assert env.store.get_take(TAKE1_ID)["stage_failures"] == 1


def test_a_coaching_stage_that_keeps_killing_the_process_ends_as_a_failed_coaching(env):
    env.seed()
    env.upload(TAKE1_ID, attempt=1)
    env.run()
    reprocess(env, TAKE1_ID, "coaching")
    for _ in range(MAX_STAGE_INTERRUPTIONS):
        env.store.begin_stage(TAKE1_ID, "coaching")
        env.worker.resume()
    take = env.take(TAKE1_ID)
    assert (take["status"], take["coaching_status"]) == ("done", "failed")


def test_a_take_waiting_in_uploaded_is_not_counted_as_interrupted(env):
    env.seed()
    env.upload(TAKE1_ID, attempt=1)
    for _ in range(MAX_STAGE_INTERRUPTIONS + 1):
        env.worker.resume()
    assert env.take(TAKE1_ID)["status"] == "uploaded"


def test_the_database_survives_a_reopen_and_migrations_run_once(env):
    env.seed()
    env.upload(TAKE1_ID, attempt=1)
    env.run()
    again = Store(env.data_dir, clock=FakeClock())
    assert again.get_take(TAKE1_ID)["status"] == "done"
    with closing(sqlite3.connect(env.store.db_path)) as conn:
        assert conn.execute("SELECT version FROM schema_migrations").fetchall() == [
            (1,),
            (2,),
            (3,),
        ]
        assert conn.execute("PRAGMA journal_mode").fetchone()[0] == "wal"


def test_a_newer_database_is_refused(env):
    with closing(sqlite3.connect(env.store.db_path)) as conn:
        conn.execute("INSERT INTO schema_migrations VALUES (99, 'later')")
        conn.commit()
    with pytest.raises(RuntimeError, match="newer"):
        Store(env.data_dir)


def test_stop_ends_the_worker_thread(env):
    env.worker.start()
    assert env.worker._thread.is_alive()
    thread = env.worker._thread
    env.worker.stop()
    assert not thread.is_alive()
