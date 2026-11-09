"""Auth, the error body, and every error code in the contract's table that a request can reach."""

from __future__ import annotations

import json

import pytest
from fastapi.testclient import TestClient
from support import (
    PROMPT_ID,
    SESSION_ID,
    TAKE1_ID,
    TAKE2_ID,
    TAKE_METADATA,
    TOKEN,
    build_env,
    sha256,
    wav_bytes,
)

from speakup.api import routes


def error_of(response, status: int, code: str) -> dict:
    assert response.status_code == status, response.text
    body = response.json()
    assert list(body) == ["error"]
    assert list(body["error"]) == ["code", "message", "details"]
    assert body["error"]["code"] == code
    assert isinstance(body["error"]["message"], str)
    return body["error"]


# -- 401 ------------------------------------------------------------------------------------


@pytest.mark.parametrize(
    "headers",
    [
        {},
        {"Authorization": "Bearer wrong"},
        {"Authorization": f"Basic {TOKEN}"},
        {"Authorization": TOKEN},
        {"Authorization": "Bearer "},
        {"Authorization": f"Bearer {TOKEN}x"},
    ],
)
@pytest.mark.parametrize(
    ("method", "path"),
    [
        ("GET", "/v1/health"),
        ("GET", "/v1/sessions"),
        ("PUT", f"/v1/sessions/{SESSION_ID}"),
        ("GET", f"/v1/takes/{TAKE1_ID}"),
        ("GET", "/v1/no-such-endpoint"),
    ],
)
def test_wrong_or_missing_token_gets_401_and_nothing_else(env, headers, method, path):
    client = TestClient(env.client.app)
    # Even a body that cannot be parsed must not get past the token check.
    response = client.request(method, path, headers=headers, content=b"{not json")
    error = error_of(response, 401, "unauthorized")
    assert error["details"] is None
    assert response.headers["www-authenticate"] == "Bearer"


def test_bearer_scheme_is_case_insensitive(env):
    client = TestClient(env.client.app, headers={"Authorization": f"bearer {TOKEN}"})
    assert client.get("/v1/health").status_code == 200


def test_the_server_refuses_to_start_without_a_token(env, monkeypatch):
    from speakup.api import create_app

    monkeypatch.delenv("SPEAKUP_API_TOKEN", raising=False)
    monkeypatch.setattr("speakup.config._FILE_VALUES", {})
    with pytest.raises(RuntimeError, match="SPEAKUP_API_TOKEN"):
        create_app(worker=env.worker)


# -- 400 ------------------------------------------------------------------------------------


def test_malformed_json_is_bad_request(env):
    response = env.client.put(
        f"/v1/sessions/{SESSION_ID}", content=b"{oops", headers={"Content-Type": "application/json"}
    )
    error_of(response, 400, "bad_request")


def test_upload_that_is_not_multipart_is_bad_request(env):
    env.seed()
    response = env.client.put(f"/v1/takes/{TAKE1_ID}", json={"prompt_id": PROMPT_ID})
    error_of(response, 400, "bad_request")


def test_upload_without_audio_or_metadata_is_bad_request(env):
    env.seed()
    valid = {**TAKE_METADATA, "audio_sha256": sha256(wav_bytes())}
    meta = ("metadata", (None, json.dumps(valid), "application/json"))
    error_of(env.client.put(f"/v1/takes/{TAKE1_ID}", files=[meta]), 400, "bad_request")
    audio = ("audio", ("a.wav", wav_bytes(), "audio/wav"))
    error_of(env.client.put(f"/v1/takes/{TAKE1_ID}", files=[audio]), 400, "bad_request")


def test_upload_with_unreadable_metadata_is_bad_request(env):
    env.seed()
    files = [
        ("metadata", (None, "not json", "application/json")),
        ("audio", ("a.wav", wav_bytes(), "audio/wav")),
    ]
    error_of(env.client.put(f"/v1/takes/{TAKE1_ID}", files=files), 400, "bad_request")
    files[0] = ("metadata", (None, "[1]", "application/json"))
    error_of(env.client.put(f"/v1/takes/{TAKE1_ID}", files=files), 400, "bad_request")


# -- 404 ------------------------------------------------------------------------------------


@pytest.mark.parametrize(
    "path",
    [
        f"/v1/sessions/{SESSION_ID}",
        f"/v1/prompts/{PROMPT_ID}",
        f"/v1/takes/{TAKE1_ID}",
        f"/v1/takes/{TAKE1_ID}/report",
        f"/v1/takes/{TAKE1_ID}/comparison",
        f"/v1/takes/{TAKE1_ID}/audio",
    ],
)
def test_unknown_id_in_the_path_is_not_found(env, path):
    error = error_of(env.client.get(path), 404, "not_found")
    assert error["message"].startswith("No ")
    assert error["details"] is None


def test_unknown_id_for_patch_and_reprocess_is_not_found(env):
    error_of(env.client.patch(f"/v1/sessions/{SESSION_ID}", json={}), 404, "not_found")
    response = env.client.post(f"/v1/takes/{TAKE1_ID}/reprocess", json={"from_stage": "coaching"})
    error_of(response, 404, "not_found")


def test_unknown_endpoint_is_not_found(env):
    error_of(env.client.get("/v1/nothing"), 404, "not_found")


def test_unknown_parent_in_the_body_names_the_field(env):
    error = error_of(env.put_prompt(), 404, "not_found")
    assert error["details"] == {"field": "session_id"}
    env.seed()
    response = env.upload(TAKE1_ID, prompt_id="11111111-2222-4333-8444-555555555555")
    error = error_of(response, 404, "not_found")
    assert error["details"] == {"field": "prompt_id"}


def test_comparison_without_a_previous_take(env):
    env.seed()
    env.upload_story_takes()
    env.run()
    error_of(env.client.get(f"/v1/takes/{TAKE1_ID}/comparison"), 404, "no_previous_take")


def test_comparison_when_the_earlier_take_did_not_finish(env):
    env.seed()
    env.engine.words = 2  # attempt 1 fails with no_speech
    env.upload(TAKE1_ID, attempt=1, recorded_at="2026-11-09T08:15:01.000Z")
    env.run()
    assert env.take(TAKE1_ID)["status"] == "failed"
    env.engine.words = 20
    env.upload(TAKE2_ID)
    env.run()
    assert env.take(TAKE2_ID)["status"] == "done"
    assert env.take(TAKE2_ID)["previous_take_id"] is None
    error_of(env.client.get(f"/v1/takes/{TAKE2_ID}/comparison"), 404, "no_previous_take")
    assert env.client.get(f"/v1/takes/{TAKE2_ID}/report").json()["has_comparison"] is False


# -- 409 ------------------------------------------------------------------------------------


def test_reusing_a_session_id_with_other_content_conflicts(env):
    env.seed()
    error_of(env.put_session(mode="driving"), 409, "conflict")
    error_of(env.put_session(started_at="2026-11-09T09:00:00.000Z"), 409, "conflict")


def test_reusing_a_prompt_id_with_other_content_conflicts(env):
    env.seed()
    error_of(env.put_prompt(text="A different question?"), 409, "conflict")
    error_of(env.put_prompt(target_seconds=120), 409, "conflict")


def test_reusing_a_take_id_with_other_audio_conflicts(env):
    env.seed()
    assert env.upload(TAKE1_ID, attempt=1).status_code == 201
    other = wav_bytes(seconds=2.0)
    error_of(env.upload(TAKE1_ID, attempt=1, audio=other), 409, "conflict")


def test_a_taken_attempt_conflicts(env):
    env.seed()
    assert env.upload(TAKE1_ID, attempt=2).status_code == 201
    error = error_of(env.upload(TAKE2_ID, attempt=2), 409, "conflict")
    assert "Attempt 2" in error["message"]
    # The rejected upload left nothing behind.
    assert env.client.get(f"/v1/takes/{TAKE2_ID}").status_code == 404
    assert not (env.data_dir / "takes" / TAKE2_ID).exists()
    assert list((env.data_dir / "tmp").iterdir()) == []


def test_report_and_comparison_before_analysis_say_not_ready(env):
    env.seed()
    env.upload_story_takes()
    error = error_of(env.client.get(f"/v1/takes/{TAKE2_ID}/report"), 409, "not_ready")
    assert error["details"] == {"status": "uploaded"}
    error = error_of(env.client.get(f"/v1/takes/{TAKE2_ID}/comparison"), 409, "not_ready")
    assert error["details"] == {"status": "uploaded"}


def test_report_of_a_failed_take_says_not_ready_with_its_status(env):
    env.seed()
    env.engine.words = 1
    env.upload(TAKE1_ID, attempt=1)
    env.run()
    error = error_of(env.client.get(f"/v1/takes/{TAKE1_ID}/report"), 409, "not_ready")
    assert error["details"] == {"status": "failed"}


def test_reprocess_while_processing_is_invalid_state(env):
    env.seed()
    env.upload(TAKE1_ID, attempt=1)
    response = env.client.post(f"/v1/takes/{TAKE1_ID}/reprocess", json={"from_stage": "coaching"})
    error_of(response, 409, "invalid_state")
    env.store.begin_stage(TAKE1_ID, "analyzing")
    response = env.client.post(f"/v1/takes/{TAKE1_ID}/reprocess", json={"from_stage": "coaching"})
    error_of(response, 409, "invalid_state")


# -- 413, 415, 422 --------------------------------------------------------------------------


def test_audio_over_the_limit_is_rejected_after_reading(env, monkeypatch):
    env.seed()
    monkeypatch.setattr(routes, "MAX_AUDIO_BYTES", 1000)
    error_of(env.upload(TAKE1_ID, attempt=1), 413, "payload_too_large")
    assert env.client.get(f"/v1/takes/{TAKE1_ID}").status_code == 404
    assert list((env.data_dir / "tmp").iterdir()) == []


def test_audio_over_the_limit_is_rejected_from_the_declared_length(env, monkeypatch):
    env.seed()
    monkeypatch.setattr(routes, "MAX_AUDIO_BYTES", 1000)
    monkeypatch.setattr(routes, "MULTIPART_OVERHEAD", 0)
    error_of(env.upload(TAKE1_ID, attempt=1), 413, "payload_too_large")


def test_audio_that_is_not_wav_is_unsupported(env):
    env.seed()
    for junk in (b"ID3" + b"\x00" * 200, b"", b"RIFF"):
        error_of(env.upload(TAKE1_ID, attempt=1, audio=junk), 415, "unsupported_media_type")
    assert list((env.data_dir / "tmp").iterdir()) == []


def test_hash_mismatch_is_a_validation_failure_and_stores_nothing(env):
    env.seed()
    response = env.upload(TAKE1_ID, attempt=1, sha=sha256(b"something else"))
    error = error_of(response, 422, "validation_failed")
    assert error["details"]["errors"][0]["field"] == "audio_sha256"
    assert env.client.get(f"/v1/takes/{TAKE1_ID}").status_code == 404
    assert not (env.data_dir / "takes" / TAKE1_ID).exists()
    assert list((env.data_dir / "tmp").iterdir()) == []


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("attempt", 0),
        ("attempt", "2"),
        ("duration_s", -1),
        ("recorded_at", "yesterday"),
        ("recorded_at", "2026-11-09T08:19:47"),
        ("audio_sha256", "abc"),
        ("prompt_id", "not-a-uuid"),
    ],
)
def test_bad_take_metadata_is_a_validation_failure(env, field, value):
    env.seed()
    response = env.upload(TAKE1_ID, **{field: value})
    error = error_of(response, 422, "validation_failed")
    assert error["details"]["errors"][0]["field"] == field
    assert error["details"]["errors"][0]["message"]


def test_missing_metadata_fields_are_listed(env):
    env.seed()
    files = {
        "metadata": (None, json.dumps({"attempt": 1}), "application/json"),
        "audio": ("a.wav", wav_bytes(), "audio/wav"),
    }
    error = error_of(env.client.put(f"/v1/takes/{TAKE1_ID}", files=files), 422, "validation_failed")
    fields = {e["field"] for e in error["details"]["errors"]}
    assert fields == {"prompt_id", "recorded_at", "duration_s", "audio_sha256"}


@pytest.mark.parametrize(
    "body",
    [
        {"mode": "walking", "started_at": "2026-11-09T08:12:03.115Z"},
        {"mode": "home"},
        {"mode": "home", "started_at": "2026-11-09T08:12:03.115Z", "nervousness_before": 6},
        {"mode": "home", "started_at": "2026-11-09T08:12:03.115Z", "nervousness_before": 0},
    ],
)
def test_bad_session_bodies_are_validation_failures(env, body):
    response = env.client.put(f"/v1/sessions/{SESSION_ID}", json=body)
    error = error_of(response, 422, "validation_failed")
    assert error["details"]["errors"]


def test_a_path_id_that_is_not_a_uuid_is_a_validation_failure(env):
    response = env.put_session(session_id="not-a-uuid")
    error = error_of(response, 422, "validation_failed")
    assert error["details"]["errors"][0]["field"] == "session_id"


@pytest.mark.parametrize(
    ("override", "field"),
    [
        ({"notes": "a note"}, "notes"),  # impromptu with notes
        ({"category": "nonsense"}, "category"),
        ({"target_seconds": 10}, "target_seconds"),
        ({"target_seconds": 901}, "target_seconds"),
        ({"text": "   "}, "text"),
        ({"question_source": "dictated"}, "question_source"),
        ({"kind": "prepared"}, "category"),  # prepared with a category
    ],
)
def test_bad_prompts_are_validation_failures(env, override, field):
    env.seed()
    response = env.put_prompt(prompt_id="22222222-3333-4444-8555-666666666666", **override)
    error = error_of(response, 422, "validation_failed")
    assert error["details"]["errors"][0]["field"] == field


def test_query_parameters_are_validated(env):
    for query in ("limit=0", "limit=101", "limit=abc", "before=yesterday"):
        error_of(env.client.get(f"/v1/sessions?{query}"), 422, "validation_failed")


def test_questions_request_is_validated(env):
    for body in ({"count": 0}, {"count": 11}, {"category": "nonsense"}):
        error_of(env.client.post("/v1/questions", json=body), 422, "validation_failed")


def test_reprocess_request_is_validated(env):
    env.seed()
    env.upload(TAKE1_ID, attempt=1)
    response = env.client.post(f"/v1/takes/{TAKE1_ID}/reprocess", json={"from_stage": "nope"})
    error_of(response, 422, "validation_failed")
    error_of(env.client.post(f"/v1/takes/{TAKE1_ID}/reprocess", json={}), 422, "validation_failed")


# -- 500 ------------------------------------------------------------------------------------


def test_a_bug_is_an_internal_error_with_a_generic_message(tmp_path):
    env = build_env(tmp_path / "data", raise_server_exceptions=False)
    env.seed()
    env.upload_story_takes()
    env.run()

    def boom(previous, current):
        raise RuntimeError("secret detail that must not leak")

    env.analyzer.compare_metrics = boom
    response = env.client.get(f"/v1/takes/{TAKE2_ID}/comparison")
    error = error_of(response, 500, "internal")
    assert "secret detail" not in response.text
    assert error["details"] is None
