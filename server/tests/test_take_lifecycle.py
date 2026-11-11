"""The whole take lifecycle, with fakes, checked against the doc's examples field for field."""

from __future__ import annotations

import copy

from support import (
    ANALYSIS_EXAMPLE,
    COACHING_EXAMPLE,
    COMPARISON_EXAMPLE,
    HEALTH_EXAMPLE,
    PROMPT_ID,
    REPORT_SKETCH,
    SESSION_DETAIL,
    SESSION_ID,
    SESSION_PATCH,
    SESSIONS_LIST,
    TAKE1_ID,
    TAKE2_ID,
    TAKE_DONE,
    TAKE_UPLOADED,
    wav_bytes,
)

DONE_AT = TAKE_DONE["status_changed_at"]


def test_story_from_upload_to_done(env):
    env.seed()
    env.upload_story_takes()

    # The upload response is the doc's Take resource.
    assert env.take(TAKE2_ID) == TAKE_UPLOADED
    assert env.client.get("/v1/health").json()["queue_length"] == 2

    env.clock.set(DONE_AT)
    assert env.run() == 2

    # The recordings were processed oldest first, through every status.
    assert [a["take_id"] for a in env.analyzer.analyze_calls] == [TAKE1_ID, TAKE2_ID]
    assert env.engine.statuses == ["transcribing", "transcribing"]
    assert env.analyzer.statuses == ["analyzing", "analyzing"]
    assert env.coach.statuses == ["coaching", "coaching"]

    # GET /v1/takes/{id} is the doc's done example.
    assert env.take(TAKE2_ID) == TAKE_DONE
    first = env.take(TAKE1_ID)
    assert first["status"] == "done"
    assert first["previous_take_id"] is None
    assert first["summary"] == {
        "verdict": COACHING_EXAMPLE["verdict"],
        "focus_titles": ["Number your reasons", "Stop silently, not mid-phrase"],
        "fillers_per_100_words": 3.74,
        "blocks": 4,
        "restarts": 2,
        "wpm_voiced": 180.1,
    }

    # The retry's coaching request carried the previous take's finalized analysis and report.
    retry_request = env.coach.requests[1]
    assert retry_request["previous"]["attempt"] == 1
    assert retry_request["previous"]["analysis"] == ANALYSIS_EXAMPLE
    assert retry_request["previous"]["coaching"]["take_id"] == TAKE1_ID
    assert env.coach.requests[0]["previous"] is None
    assert env.coach.requests[0]["prompt"] == {
        "kind": "impromptu",
        "text": "Why did we choose Postgres over DynamoDB for the billing service?",
        "notes": None,
        "category": "decision",
        "target_seconds": 90,
        "language": "en",
    }
    assert env.coach.requests[0]["mode"] == "home"
    assert env.coach.requests[0]["attempt"] == 1

    # Report: the finalized analysis and coaching exactly as in the doc.
    report = env.client.get(f"/v1/takes/{TAKE1_ID}/report")
    assert report.status_code == 200
    body = report.json()
    assert list(body) == list(REPORT_SKETCH)
    assert body["analysis"] == ANALYSIS_EXAMPLE
    assert body["coaching"] == COACHING_EXAMPLE
    assert body["has_comparison"] is False
    assert body["take"] == first
    for key, value in REPORT_SKETCH["take"].items():
        assert body["take"][key] == value
    assert body["prompt"] == {
        "id": PROMPT_ID,
        "session_id": SESSION_ID,
        "kind": "impromptu",
        "text": REPORT_SKETCH["prompt"]["text"],
        "notes": None,
        "category": "decision",
        "target_seconds": 90,
        "question_source": "claude",
        "language": "en",
        "theme": None,
        "created_at": "2026-11-09T08:12:40.880Z",
    }
    retry_report = env.client.get(f"/v1/takes/{TAKE2_ID}/report").json()
    assert retry_report["has_comparison"] is True
    assert retry_report["coaching"]["comparison"]["summary"] == COMPARISON_EXAMPLE["summary"]

    # Comparison on the retry is the doc's example; attempt 1 has none.
    comparison = env.client.get(f"/v1/takes/{TAKE2_ID}/comparison")
    assert comparison.status_code == 200
    assert comparison.json() == COMPARISON_EXAMPLE
    assert env.client.get(f"/v1/takes/{TAKE1_ID}/comparison").status_code == 404

    # Audio is the original upload.
    audio = env.client.get(f"/v1/takes/{TAKE2_ID}/audio")
    assert audio.status_code == 200
    assert audio.headers["content-type"] == "audio/wav"
    assert audio.content == wav_bytes(tone=int(TAKE2_ID[:2], 16))
    assert (env.data_dir / "takes" / TAKE2_ID / "audio16k.wav").is_file()

    # Sessions: end it, then the list and detail match the doc.
    env.clock.set(SESSION_DETAIL["updated_at"])
    patched = env.client.patch(f"/v1/sessions/{SESSION_ID}", json=SESSION_PATCH)
    assert patched.status_code == 200
    assert patched.json() == {k: v for k, v in SESSION_DETAIL.items() if k != "prompts"}

    listing = env.client.get("/v1/sessions")
    assert listing.status_code == 200
    assert listing.json() == SESSIONS_LIST

    detail = env.client.get(f"/v1/sessions/{SESSION_ID}").json()
    assert [t["id"] for t in detail["prompts"][0]["takes"]] == [TAKE1_ID, TAKE2_ID]
    assert detail["prompts"][0]["takes"] == [first, env.take(TAKE2_ID)]
    detail["prompts"][0]["takes"] = []
    assert detail == SESSION_DETAIL

    assert env.client.get("/v1/health").json()["queue_length"] == 0


def test_health_matches_the_example(env):
    body = env.client.get("/v1/health").json()
    assert list(body) == list(HEALTH_EXAMPLE)
    expected = copy.deepcopy(HEALTH_EXAMPLE)
    expected["server_version"] = body["server_version"]
    assert body == expected
    assert isinstance(body["server_version"], str)


def test_status_progress_is_visible_to_pollers(env):
    env.seed()
    env.upload_story_takes()
    seen: list[str] = []
    original = env.analyzer.analyze

    def spy(**kwargs):
        seen.append(env.take(kwargs["take_id"])["status"])
        return original(**kwargs)

    env.analyzer.analyze = spy
    env.run()
    assert seen == ["analyzing", "analyzing"]
    assert env.take(TAKE1_ID)["status_changed_at"] == env.clock.value


def test_worker_thread_picks_up_an_upload(env):
    env.seed()
    with env.client:  # runs the app's lifespan, which starts the worker thread
        env.upload_story_takes()
        deadline_polls = 200
        for _ in range(deadline_polls):
            if env.take(TAKE2_ID)["status"] == "done":
                break
            import time

            time.sleep(0.05)
        assert env.take(TAKE2_ID)["status"] == "done"
        assert env.take(TAKE1_ID)["status"] == "done"
    assert env.engine.prepared >= 1
