"""Sessions, prompts, questions and uploads: shapes, idempotent creates and edge cases."""

from __future__ import annotations

import time

from support import (
    PROMPT_ID,
    PROMPT_REQUEST,
    QUESTIONS_EXAMPLE,
    SESSION_ID,
    SESSION_RESOURCE,
    TAKE1_ID,
    TAKE2_ID,
    TAKE_UPLOADED,
    wav_bytes,
)


def test_put_session_matches_the_example_and_is_idempotent(env):
    env.clock.set(SESSION_RESOURCE["created_at"])
    created = env.put_session()
    assert created.status_code == 201
    assert created.json() == SESSION_RESOURCE

    env.clock.set("2026-11-09T09:30:00.000Z")
    again = env.put_session(nervousness_before=5)  # other fields of a repeat are ignored
    assert again.status_code == 200
    assert again.json() == SESSION_RESOURCE


def test_put_session_accepts_timestamps_without_milliseconds_and_offsets(env):
    env.clock.set(SESSION_RESOURCE["created_at"])
    response = env.put_session(started_at="2026-11-09T10:12:03+02:00", nervousness_before=None)
    assert response.status_code == 201
    assert response.json()["started_at"] == "2026-11-09T08:12:03.000Z"
    assert response.json()["nervousness_before"] is None
    repeat = env.put_session(started_at="2026-11-09T08:12:03Z")
    assert repeat.status_code == 200


def test_ids_are_case_insensitive(env):
    env.clock.set(SESSION_RESOURCE["created_at"])
    assert env.put_session(session_id=SESSION_ID.upper()).json()["id"] == SESSION_ID
    assert env.client.get(f"/v1/sessions/{SESSION_ID.upper()}").status_code == 200


def test_patch_session_sets_clears_and_ends(env):
    env.seed()
    env.clock.set("2026-11-09T08:41:50.311Z")
    response = env.client.patch(f"/v1/sessions/{SESSION_ID}", json={"nervousness_after": 2})
    assert response.json()["nervousness_after"] == 2
    assert response.json()["updated_at"] == "2026-11-09T08:41:50.311Z"
    assert response.json()["nervousness_before"] == 3  # untouched

    cleared = env.client.patch(f"/v1/sessions/{SESSION_ID}", json={"nervousness_before": None})
    assert cleared.json()["nervousness_before"] is None
    assert cleared.json()["nervousness_after"] == 2

    ended = env.client.patch(
        f"/v1/sessions/{SESSION_ID}", json={"ended_at": "2026-11-09T08:41:50Z"}
    )
    assert ended.json()["ended_at"] == "2026-11-09T08:41:50.000Z"

    # A null ended_at cannot clear it; an unrelated change leaves it alone.
    refused = env.client.patch(f"/v1/sessions/{SESSION_ID}", json={"ended_at": None})
    assert refused.status_code == 422
    assert refused.json()["error"]["details"]["errors"][0]["field"] == "ended_at"
    again = env.client.patch(f"/v1/sessions/{SESSION_ID}", json={"nervousness_after": 4})
    assert again.json()["ended_at"] == "2026-11-09T08:41:50.000Z"

    # An empty patch changes nothing, not even updated_at.
    before = env.client.get(f"/v1/sessions/{SESSION_ID}").json()["updated_at"]
    env.clock.set("2026-11-09T12:00:00.000Z")
    empty = env.client.patch(f"/v1/sessions/{SESSION_ID}", json={})
    assert empty.json()["updated_at"] == before


def test_session_list_is_newest_first_and_pages(env):
    ids = [f"00000000-0000-4000-8000-00000000000{n}" for n in range(1, 4)]
    for n, session_id in enumerate(ids, start=1):
        env.clock.set(f"2026-11-0{n}T08:00:00.000Z")
        started = f"2026-11-0{n}T08:00:00.000Z"
        assert env.put_session(session_id, started_at=started).status_code == 201

    first = env.client.get("/v1/sessions?limit=2").json()
    assert [s["id"] for s in first["sessions"]] == [ids[2], ids[1]]
    assert first["next_before"] == "2026-11-02T08:00:00.000Z"
    assert first["sessions"][0]["prompts"] == []
    assert first["sessions"][0]["take_count"] == 0

    second = env.client.get(f"/v1/sessions?limit=2&before={first['next_before']}").json()
    assert [s["id"] for s in second["sessions"]] == [ids[0]]
    assert second["next_before"] is None

    everything = env.client.get("/v1/sessions").json()
    assert [s["id"] for s in everything["sessions"]] == [ids[2], ids[1], ids[0]]
    assert everything["next_before"] is None


def test_prompt_create_matches_the_example_and_is_idempotent(env):
    env.clock.set(SESSION_RESOURCE["created_at"])
    env.put_session()
    env.clock.set("2026-11-09T08:12:40.880Z")
    created = env.put_prompt()
    assert created.status_code == 201
    assert created.json() == {
        "id": PROMPT_ID,
        "session_id": SESSION_ID,
        **{k: v for k, v in PROMPT_REQUEST.items() if k != "session_id"},
        "created_at": "2026-11-09T08:12:40.880Z",
    }
    env.clock.set("2026-11-09T09:00:00.000Z")
    repeat = env.put_prompt()
    assert repeat.status_code == 200
    assert repeat.json()["created_at"] == "2026-11-09T08:12:40.880Z"

    detail = env.client.get(f"/v1/prompts/{PROMPT_ID}").json()
    assert detail["takes"] == []
    assert detail["text"] == PROMPT_REQUEST["text"]


def test_prepared_prompt_keeps_its_notes(env):
    env.seed()
    prompt_id = "33333333-4444-4555-8666-777777777777"
    body = {
        "kind": "prepared",
        "text": "Today's stand-up",
        "notes": "Shipped the invoice export. Blocked on the tax API keys.",
        "category": None,
        "target_seconds": 120,
        "question_source": "typed",
    }
    response = env.put_prompt(prompt_id, **body)
    assert response.status_code == 201
    assert response.json()["notes"] == body["notes"]
    assert response.json()["category"] is None
    session = env.client.get(f"/v1/sessions/{SESSION_ID}").json()
    assert [p["id"] for p in session["prompts"]] == [PROMPT_ID, prompt_id]


def test_questions_avoid_the_request_and_the_recent_prompts(env):
    env.seed()
    response = env.client.post(
        "/v1/questions",
        json={"count": 3, "category": "decision", "exclude": ["Something Ryan just saw?"]},
    )
    assert response.status_code == 200
    assert response.json() == QUESTIONS_EXAMPLE
    assert env.coach.question_calls == [
        {
            "count": 3,
            "category": "decision",
            "exclude": ["Something Ryan just saw?", PROMPT_REQUEST["text"]],
            "track": "work",
            "language": "en",
        }
    ]
    # Defaults: three questions, any category, nothing excluded but what is stored.
    env.client.post("/v1/questions", json={})
    assert env.coach.question_calls[1]["count"] == 3
    assert env.coach.question_calls[1]["category"] is None


def test_an_empty_question_list_is_a_normal_answer(env):
    # Without a key the bank can run out of unseen questions in a category.
    env.coach.generate_questions = lambda **kwargs: {"source": "bank", "questions": []}
    response = env.client.post("/v1/questions", json={"count": 3, "category": "decision"})
    assert response.status_code == 200
    assert response.json() == {"source": "bank", "questions": []}


def test_upload_creates_the_take_and_is_idempotent(env):
    env.seed()
    env.clock.set(TAKE_UPLOADED["created_at"])
    first = env.upload(TAKE2_ID)
    assert first.status_code == 201
    # Attempt 1 does not exist here, so there is no previous take yet.
    expected = {**TAKE_UPLOADED, "previous_take_id": None}
    assert first.json() == expected
    assert (env.data_dir / "takes" / TAKE2_ID / "original.wav").read_bytes() == wav_bytes(
        tone=int(TAKE2_ID[:2], 16)
    )

    env.clock.set("2026-11-09T09:00:00.000Z")
    repeat = env.upload(TAKE2_ID)
    assert repeat.status_code == 200
    assert repeat.json() == expected  # nothing about the take changed
    assert env.store.queue_length() == 1
    assert list((env.data_dir / "tmp").iterdir()) == []


def test_a_repeated_upload_after_processing_returns_the_current_take(env):
    env.seed()
    env.upload(TAKE1_ID, attempt=1)
    env.run()
    repeat = env.upload(TAKE1_ID, attempt=1)
    assert repeat.status_code == 200
    assert repeat.json()["status"] == "done"
    assert env.store.queue_length() == 0


def test_metadata_may_be_sent_as_a_file_part_and_unknown_keys_are_ignored(env):
    env.seed()
    response = env.upload(TAKE1_ID, attempt=1, metadata_filename="metadata.json", future_key=1)
    assert response.status_code == 201
    assert "future_key" not in response.json()


def test_mic_route_is_optional_and_any_string(env):
    env.seed()
    assert env.upload(TAKE1_ID, attempt=1, mic_route=None).json()["mic_route"] is None
    assert env.upload(TAKE2_ID, mic_route="airplay").json()["mic_route"] == "airplay"


def test_polling_loop_sees_a_take_finish(env):
    env.seed()
    with env.client:
        env.upload(TAKE1_ID, attempt=1)
        for _ in range(200):
            if env.take(TAKE1_ID)["status"] == "done":
                break
            time.sleep(0.02)
    assert env.take(TAKE1_ID)["status"] == "done"
