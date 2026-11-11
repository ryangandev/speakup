"""Snapshots of the requests the coaching module sends, so prompt changes show in diffs.

To accept an intended change, run:
    SPEAKUP_UPDATE_SNAPSHOTS=1 uv run pytest tests/test_coaching_request.py
and review the diff under tests/snapshots/coaching/.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

import pytest
from anthropic.lib._parse._transform import transform_schema
from coaching_helpers import FakeClient, output_example, reply, request, retry_output, retry_request

from speakup.coaching import claude as claude_mod
from speakup.coaching import coach_take, generate_questions, learn_themes
from speakup.coaching.models import (
    CoachingOutput,
    InterestQuestionList,
    QuestionList,
    ThemeList,
    output_schema,
)

SNAPSHOTS = Path(__file__).parent / "snapshots" / "coaching"
UPDATE = os.environ.get("SPEAKUP_UPDATE_SNAPSHOTS") == "1"


def assert_snapshot(name: str, actual: str) -> None:
    path = SNAPSHOTS / name
    if UPDATE:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(actual, encoding="utf-8")
        return
    assert path.exists(), f"missing snapshot {name}; run with SPEAKUP_UPDATE_SNAPSHOTS=1"
    assert actual == path.read_text(encoding="utf-8"), (
        f"{name} changed; if intended, rerun with SPEAKUP_UPDATE_SNAPSHOTS=1 and review the diff"
    )


def _dump(value: Any) -> str:
    return json.dumps(value, indent=2, ensure_ascii=False) + "\n"


def _split(call: dict[str, Any]) -> tuple[str, list[str], dict[str, Any], dict[str, Any]]:
    """System text, user blocks, schema, and the remaining parameters of one call."""
    params = json.loads(json.dumps(call))
    system = params.pop("system")
    assert len(system) == 1 and system[0]["cache_control"] == {"type": "ephemeral"}
    messages = params.pop("messages")
    assert [m["role"] for m in messages] == ["user"]
    user = [block["text"] for block in messages[0]["content"]]
    schema = params["output_config"].pop("format")
    assert schema["type"] == "json_schema"
    return system[0]["text"], user, schema["schema"], params


@pytest.fixture
def fake(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> FakeClient:
    client = FakeClient()
    monkeypatch.setattr(claude_mod, "api_key", lambda: "test-key")
    monkeypatch.setattr(claude_mod, "model", lambda: "claude-opus-5-5")
    monkeypatch.setattr(claude_mod, "client", lambda: client)
    monkeypatch.setattr(claude_mod, "data_dir", lambda: tmp_path)
    return client


def test_first_take_request(fake: FakeClient) -> None:
    fake.replies.append(reply(output_example()))
    coach_take(request())

    system, user, schema, params = _split(fake.calls[0])
    assert_snapshot("coach_system.md", system)
    assert_snapshot("coach_user_first_take.txt", user[0] + "\n")
    assert_snapshot("coach_schema.json", _dump(schema))
    assert_snapshot("coach_params.json", _dump(params))


def test_retry_request(fake: FakeClient) -> None:
    fake.replies.append(reply(retry_output()))
    coach_take(retry_request())

    _, user, _, _ = _split(fake.calls[0])
    assert_snapshot("coach_user_retry.txt", user[0] + "\n")


def test_reask_request(fake: FakeClient) -> None:
    bad = output_example()
    bad["focus"] = []
    fake.replies += [reply(bad), reply(output_example())]
    coach_take(request())

    _, user, _, _ = _split(fake.calls[1])
    assert len(user) == 2
    assert_snapshot("coach_user_reask.txt", user[1] + "\n")


def test_questions_request(fake: FakeClient, tmp_path: Path) -> None:
    (tmp_path / "profile.md").write_text("Backend engineer on the billing team.\n")
    fake.replies.append(
        reply({"questions": [{"text": "Why Kafka?", "category": "decision", "target_seconds": 90}]})
    )
    generate_questions(count=1, category="decision", exclude=["Why Postgres?"])

    system, user, schema, params = _split(fake.calls[0])
    assert_snapshot("questions_system.md", system)
    assert_snapshot("questions_user.txt", user[0] + "\n")
    assert_snapshot("questions_schema.json", _dump(schema))
    assert_snapshot("questions_params.json", _dump(params))


def test_interests_request(fake: FakeClient) -> None:
    fake.replies.append(
        reply(
            {
                "questions": [
                    {"text": f"问题 {i}", "theme": "Charisma", "target_seconds": 90}
                    for i in range(3)
                ]
            }
        )
    )
    generate_questions(
        count=3,
        category=None,
        exclude=["What does happiness mean to you?"],
        track="interests",
        language="zh",
        interests={
            "theme": "Charisma",
            "takes": 4,
            "themes": ["Happiness", "Charisma", "Travel"],
            "topics": [
                {"text": "Contentment is a quiet kind of wealth", "language": "en"},
                {"text": "个人魅力是什么", "language": "zh"},
                {"text": "被讨厌的勇气", "language": "zh"},
                {"text": "Purpose of travel", "language": "en"},
            ],
        },
    )

    system, user, schema, params = _split(fake.calls[0])
    assert_snapshot("interests_system.md", system)
    assert_snapshot("interests_user.txt", user[0] + "\n")
    assert_snapshot("interests_schema.json", _dump(schema))
    assert_snapshot("interests_params.json", _dump(params))


def test_themes_request(fake: FakeClient) -> None:
    fake.replies.append(reply({"themes": ["Happiness", "Charisma"]}))
    learn_themes(
        topics=[
            {"text": "Contentment is a quiet kind of wealth", "language": "en"},
            {"text": "个人魅力是什么", "language": "zh"},
            {"text": "What is happiness", "language": "en"},
        ],
        current=["Happiness"],
        hidden=["Stand-ups"],
    )

    system, user, schema, params = _split(fake.calls[0])
    assert_snapshot("themes_system.md", system)
    assert_snapshot("themes_user.txt", user[0] + "\n")
    assert_snapshot("themes_schema.json", _dump(schema))
    assert_snapshot("themes_params.json", _dump(params))


@pytest.mark.parametrize("model", [CoachingOutput, QuestionList, InterestQuestionList, ThemeList])
def test_schemas_meet_structured_output_rules(model: type) -> None:
    """The schema is already in the form the SDK's structured-output transform produces,
    so the API receives it unchanged: every object closed and fully required, and no
    numeric, length or array-size constraints."""
    schema = output_schema(model)
    assert transform_schema(schema) == schema

    def walk(node: Any) -> None:
        if isinstance(node, dict):
            if node.get("type") == "object":
                assert node["additionalProperties"] is False
                assert sorted(node["required"]) == sorted(node["properties"])
            for banned in (
                "minimum",
                "maximum",
                "minLength",
                "maxLength",
                "minItems",
                "maxItems",
                "default",
            ):
                assert banned not in node
            for value in node.values():
                walk(value)
        elif isinstance(node, list):
            for value in node:
                walk(value)

    walk(schema)
