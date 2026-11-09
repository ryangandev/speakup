"""generate_questions: Claude when a key exists, the built-in bank otherwise."""

from __future__ import annotations

import random
from collections import Counter
from pathlib import Path

import anthropic
import httpx2
import pytest
from coaching_helpers import FakeClient, reply

from speakup.coaching import claude as claude_mod
from speakup.coaching import generate_questions
from speakup.coaching.questions import CATEGORIES, bank, from_bank


@pytest.fixture
def no_key(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(claude_mod, "api_key", lambda: None)

    def no_client():
        raise AssertionError("no client without a key")

    monkeypatch.setattr(claude_mod, "client", no_client)


@pytest.fixture
def fake(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> FakeClient:
    client = FakeClient()
    monkeypatch.setattr(claude_mod, "api_key", lambda: "test-key")
    monkeypatch.setattr(claude_mod, "model", lambda: "claude-opus-5-5")
    monkeypatch.setattr(claude_mod, "client", lambda: client)
    monkeypatch.setattr(claude_mod, "data_dir", lambda: tmp_path)
    return client


def _q(text: str, category: str = "decision", seconds: int = 90) -> dict:
    return {"text": text, "category": category, "target_seconds": seconds}


def test_bank_has_about_forty_questions_across_the_five_categories() -> None:
    counts = Counter(q["category"] for q in bank())
    assert set(counts) == set(CATEGORIES)
    assert sum(counts.values()) == 40
    assert min(counts.values()) == 8
    texts = [q["text"] for q in bank()]
    assert len(set(texts)) == len(texts)


def test_without_a_key_questions_come_from_the_bank(no_key: None) -> None:
    result = generate_questions(count=3, category="pushback", exclude=[])
    assert result["source"] == "bank"
    assert len(result["questions"]) == 3
    for q in result["questions"]:
        assert set(q) == {"text", "category", "target_seconds"}
        assert q["category"] == "pushback"


def test_bank_never_repeats_excluded_questions(no_key: None) -> None:
    status = [q["text"] for q in bank() if q["category"] == "status"]
    exclude = [t.upper() for t in status[:6]]  # matching ignores case and spacing
    for _ in range(20):
        result = generate_questions(count=3, category="status", exclude=exclude)
        texts = {q["text"] for q in result["questions"]}
        assert texts == set(status[6:])  # only two left, so it returns two


def test_bank_returns_nothing_when_a_category_is_used_up(no_key: None) -> None:
    explain = [q["text"] for q in bank() if q["category"] == "explain"]
    result = generate_questions(count=2, category="explain", exclude=explain)
    assert result == {"source": "bank", "questions": []}


def test_bank_with_any_category_mixes_categories() -> None:
    questions = from_bank(count=10, category=None, exclude=[], rng=random.Random(1))
    assert len({q["category"] for q in questions}) > 1


def test_claude_questions_are_used_when_a_key_exists(fake: FakeClient, tmp_path: Path) -> None:
    (tmp_path / "profile.md").write_text("I work on the billing service.\n")
    fake.replies.append(reply({"questions": [_q("Why Kafka over SQS?"), _q("Why gRPC?")]}))

    result = generate_questions(count=2, category="decision", exclude=["Why Postgres?"])

    assert result == {"source": "claude", "questions": [_q("Why Kafka over SQS?"), _q("Why gRPC?")]}
    user = fake.calls[0]["messages"][0]["content"][0]["text"]
    assert "I work on the billing service." in user
    assert "Why Postgres?" in user


def test_claude_questions_drop_excluded_and_clamp_length(fake: FakeClient) -> None:
    fake.replies.append(
        reply({"questions": [_q("Why Postgres?"), _q("Why Kafka?", seconds=900), _q("Why Go?")]})
    )

    result = generate_questions(count=2, category="decision", exclude=["why  postgres?"])

    assert result["source"] == "claude"
    assert result["questions"] == [_q("Why Kafka?", seconds=300), _q("Why Go?")]


def test_too_few_usable_claude_questions_fall_back_to_the_bank(fake: FakeClient) -> None:
    fake.replies.append(reply({"questions": [_q("Why Postgres?"), _q("Ship it", "status")]}))

    result = generate_questions(count=2, category="decision", exclude=["Why Postgres?"])

    assert result["source"] == "bank"
    assert all(q["category"] == "decision" for q in result["questions"])


def test_api_error_falls_back_to_the_bank(fake: FakeClient) -> None:
    fake.replies.append(
        anthropic.APIConnectionError(request=httpx2.Request("POST", "https://example.test"))
    )

    result = generate_questions(count=3, category=None, exclude=[])

    assert result["source"] == "bank"
    assert len(result["questions"]) == 3


def test_invalid_claude_output_falls_back_to_the_bank(fake: FakeClient) -> None:
    fake.replies.append(reply("not json"))

    assert generate_questions(count=1, category=None, exclude=[])["source"] == "bank"


def test_missing_profile_is_fine(fake: FakeClient) -> None:
    fake.replies.append(reply({"questions": [_q("Why Kafka?")]}))

    generate_questions(count=1, category=None, exclude=[])

    user = fake.calls[0]["messages"][0]["content"][0]["text"]
    assert "Not given." in user
