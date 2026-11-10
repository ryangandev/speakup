"""Prompt `language` through the API, the store and the worker: the default, the round trip,
validation, the migration of an existing database, and per-language engines."""

from __future__ import annotations

import sqlite3
from contextlib import closing
from pathlib import Path

import pytest
from support import (
    PROMPT_ID,
    SESSION_ID,
    TAKE1_ID,
    TAKE2_ID,
    FakeEngine,
    build_env,
)

from speakup.api import defaults
from speakup.config import DEFAULT_STT_ENGINE_ZH, server_settings
from speakup.store import Store
from speakup.store.migrations import MIGRATION_1, MIGRATION_2

ZH_PROMPT_ID = "5a1c2b3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"


def test_a_prompt_without_language_is_english(env):
    env.seed()
    assert env.client.get(f"/v1/prompts/{PROMPT_ID}").json()["language"] == "en"
    assert env.put_prompt().json()["language"] == "en"


def test_omitting_language_repeats_an_english_prompt(env):
    env.seed()
    body = env.client.get(f"/v1/prompts/{PROMPT_ID}").json()
    request = {k: body[k] for k in ("session_id", "kind", "text", "notes", "category")}
    request |= {"target_seconds": 90, "question_source": "claude"}
    repeat = env.client.put(f"/v1/prompts/{PROMPT_ID}", json=request)
    assert repeat.status_code == 200


def test_a_mandarin_prompt_round_trips_everywhere_a_prompt_appears(env):
    env.seed()
    created = env.put_prompt(ZH_PROMPT_ID, language="zh", text="为什么选 Postgres？")
    assert created.status_code == 201
    assert created.json()["language"] == "zh"
    assert (
        env.put_prompt(ZH_PROMPT_ID, language="zh", text="为什么选 Postgres？").status_code == 200
    )

    assert env.client.get(f"/v1/prompts/{ZH_PROMPT_ID}").json()["language"] == "zh"
    detail = env.client.get(f"/v1/sessions/{SESSION_ID}").json()
    assert [p["language"] for p in detail["prompts"]] == ["en", "zh"]
    listing = env.client.get("/v1/sessions").json()
    assert [p["language"] for p in listing["sessions"][0]["prompts"]] == ["en", "zh"]


def test_the_same_prompt_id_with_another_language_conflicts(env):
    env.seed()
    response = env.put_prompt(language="zh")
    assert response.status_code == 409


@pytest.mark.parametrize("value", ["fr", "EN", "zh-CN", None, 1])
def test_an_unknown_language_is_a_validation_error(env, value):
    env.seed()
    response = env.put_prompt(ZH_PROMPT_ID, language=value)
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "validation_failed"


def test_migration_gives_existing_prompts_english(tmp_path: Path):
    data = tmp_path / "data"
    data.mkdir()
    with closing(sqlite3.connect(data / "speakup.db")) as conn:
        conn.executescript(MIGRATION_1 + MIGRATION_2)
        conn.executescript(
            "INSERT INTO schema_migrations VALUES (1, 'x'), (2, 'x');"
            "INSERT INTO sessions VALUES ('s', 'home', 't', NULL, NULL, NULL, 't', 't');"
            "INSERT INTO prompts VALUES ('p', 's', 'prepared', 'Stand-up', NULL, NULL, 60,"
            " 'typed', 't');"
        )
        conn.commit()
    store = Store(data)
    assert store.get_prompt("p")["language"] == "en"
    with closing(sqlite3.connect(data / "speakup.db")) as conn:
        assert [v for (v,) in conn.execute("SELECT version FROM schema_migrations")] == [1, 2, 3]
        with pytest.raises(sqlite3.IntegrityError):
            conn.execute("UPDATE prompts SET language = 'fr'")


# -- the worker picks the engine by language ----------------------------------------------------


class MandarinEngine(FakeEngine):
    name = "fake-zh"


def _zh_env(tmp_path: Path, factory):
    env = build_env(tmp_path / "data", engines={"zh": factory})
    env.seed()
    assert env.put_prompt(ZH_PROMPT_ID, language="zh").status_code == 201
    return env


def test_a_mandarin_take_uses_the_mandarin_engine_and_rules(tmp_path: Path):
    built: list[MandarinEngine] = []

    def factory():
        built.append(MandarinEngine())
        return built[-1]

    env = _zh_env(tmp_path, factory)
    assert env.upload(TAKE1_ID, prompt_id=ZH_PROMPT_ID, attempt=1).status_code == 201
    assert env.upload(TAKE2_ID, prompt_id=ZH_PROMPT_ID, attempt=2).status_code == 201
    env.upload("1f0e2d3c-4b5a-4968-8776-655443322110", attempt=1)
    env.run()

    assert len(built) == 1
    assert len(built[0].calls) == 2 and built[0].prepared == 1
    assert len(env.engine.calls) == 1
    assert [c["language"] for c in env.analyzer.analyze_calls] == ["zh", "zh", "en"]
    assert [r["prompt"]["language"] for r in env.coach.requests] == ["zh", "zh", "en"]
    assert env.take(TAKE2_ID)["status"] == "done"


def test_a_missing_mandarin_engine_fails_the_take_with_the_reason(tmp_path: Path):
    calls = 0

    def factory():
        nonlocal calls
        calls += 1
        raise RuntimeError("fake-zh cannot run: its package is not installed")

    env = _zh_env(tmp_path, factory)
    env.upload(TAKE1_ID, prompt_id=ZH_PROMPT_ID, attempt=1)
    env.upload(TAKE2_ID, attempt=1)
    env.run()

    take = env.take(TAKE1_ID)
    assert take["status"] == "failed"
    assert take["error"] == {
        "code": "stt_failed",
        "message": "The Mandarin speech-to-text engine is not available: "
        "fake-zh cannot run: its package is not installed",
    }
    assert env.take(TAKE2_ID)["status"] == "done"

    # Nothing is cached after a failure: a reprocess tries to build the engine again.
    env.client.post(f"/v1/takes/{TAKE1_ID}/reprocess", json={"from_stage": "transcribing"})
    env.run()
    assert calls == 2


def test_no_mandarin_engine_configured_fails_the_take(env):
    env.seed()
    env.put_prompt(ZH_PROMPT_ID, language="zh")
    env.upload(TAKE1_ID, prompt_id=ZH_PROMPT_ID, attempt=1)
    env.run()
    assert env.take(TAKE1_ID)["error"] == {
        "code": "stt_failed",
        "message": "No speech-to-text engine is set up for Mandarin.",
    }


def test_languages_configured_with_the_same_engine_share_it(tmp_path: Path):
    env = _zh_env(tmp_path, lambda: FakeEngine())
    env.upload(TAKE1_ID, prompt_id=ZH_PROMPT_ID, attempt=1)
    env.upload(TAKE2_ID, attempt=1)
    env.run()
    assert env.worker.engine_for("zh") is env.engine
    assert len(env.engine.calls) == 2


def test_an_unregistered_mandarin_engine_names_the_setting(monkeypatch):
    monkeypatch.setenv("SPEAKUP_STT_ENGINE_ZH", "no-such-engine")
    with pytest.raises(RuntimeError, match="SPEAKUP_STT_ENGINE_ZH='no-such-engine' is not"):
        defaults.mandarin_engine(server_settings())


def test_the_mandarin_engine_default_is_one_constant(monkeypatch):
    monkeypatch.delenv("SPEAKUP_STT_ENGINE_ZH", raising=False)
    monkeypatch.setattr("speakup.config._FILE_VALUES", {})
    assert server_settings().stt_engine_zh == DEFAULT_STT_ENGINE_ZH == "qwen3-asr-1.7b"
