"""Interest questions and theme learning: levels, the bank, Claude, and its fallbacks."""

from __future__ import annotations

import random
from pathlib import Path

import anthropic
import httpx2
import pytest
from coaching_helpers import FakeClient, reply

from speakup.coaching import claude as claude_mod
from speakup.coaching import generate_questions, learn_themes
from speakup.coaching.questions import (
    InterestContext,
    from_interest_bank,
    general_themes,
    interest_bank,
    level_for,
    level_mix,
)
from speakup.coaching.themes import clean_names


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


def _context(
    theme: str | None = None, takes: int = 0, themes: list[str] | None = None
) -> InterestContext:
    return InterestContext(
        theme=theme,
        takes=takes,
        themes=themes if themes is not None else ["Happiness", "Travel"],
        topics=[{"text": "Purpose of travel", "language": "en"}],
    )


def _iq(text: str, theme: str = "Travel", seconds: int = 60) -> dict:
    return {"text": text, "theme": theme, "target_seconds": seconds}


# -- levels ------------------------------------------------------------------------------------


@pytest.mark.parametrize(("takes", "level"), [(0, 1), (2, 1), (3, 2), (7, 2), (8, 3), (40, 3)])
def test_the_level_follows_the_takes_on_a_theme(takes: int, level: int) -> None:
    assert level_for(takes) == level


def test_every_third_question_comes_from_the_level_below() -> None:
    assert level_mix(1, 3) == [1, 1, 1]
    assert level_mix(2, 3) == [2, 2, 1]
    assert level_mix(3, 6) == [3, 3, 2, 3, 3, 2]
    assert level_mix(3, 2) == [3, 3]


# -- the bank ----------------------------------------------------------------------------------


def test_the_bank_has_templates_for_every_level_in_both_languages() -> None:
    templates = interest_bank()["templates"]
    for language in ("en", "zh"):
        for level in ("1", "2", "3"):
            assert len(templates[language][level]) >= 6
            assert all("{theme}" in t for t in templates[language][level])


def test_without_a_key_interest_questions_come_from_the_bank(no_key: None) -> None:
    result = generate_questions(
        count=3,
        category=None,
        exclude=[],
        track="interests",
        language="en",
        interests=_context(theme="Happiness", takes=4),
    )
    assert result["source"] == "bank"
    questions = result["questions"]
    assert len(questions) == 3
    for q in questions:
        assert set(q) == {"text", "category", "theme", "target_seconds"}
        assert q["category"] == "interest"
        assert q["theme"] == "Happiness"
        assert "Happiness" in q["text"]
    # Level 2, with the third from level 1.
    assert [q["target_seconds"] for q in questions] == [90, 90, 60]


def test_chinese_bank_questions_name_a_general_theme_in_chinese(no_key: None) -> None:
    result = generate_questions(
        count=3,
        category=None,
        exclude=[],
        track="interests",
        language="zh",
        interests=_context(themes=[]),
    )
    questions = result["questions"]
    assert len(questions) == 3
    names = {t["en"]: t["zh"] for t in interest_bank()["general_themes"]}
    for q in questions:
        assert q["theme"] in general_themes()
        assert f"「{names[q['theme']]}」" in q["text"]
    # Any theme spreads the questions across themes.
    assert len({q["theme"] for q in questions}) == 3


def test_a_theme_of_his_own_stays_as_named_in_chinese() -> None:
    questions = from_interest_bank(
        count=2,
        context=_context(theme="被讨厌的勇气"),
        language="zh",
        exclude=[],
        rng=random.Random(3),
    )
    assert all("「被讨厌的勇气」" in q["text"] for q in questions)


def test_any_theme_draws_from_his_themes(no_key: None) -> None:
    questions = from_interest_bank(
        count=4, context=_context(), language="en", exclude=[], rng=random.Random(1)
    )
    assert {q["theme"] for q in questions} == {"Happiness", "Travel"}


def test_the_bank_never_repeats_excluded_questions() -> None:
    templates = interest_bank()["templates"]["en"]["1"]
    exclude = [t.format(theme="Travel").upper() for t in templates[:-1]]
    for seed in range(10):
        questions = from_interest_bank(
            count=3,
            context=_context(theme="Travel"),
            language="en",
            exclude=exclude,
            rng=random.Random(seed),
        )
        assert [q["text"] for q in questions] == [templates[-1].format(theme="Travel")]


# -- Claude --------------------------------------------------------------------------------------


def test_claude_interest_questions_keep_the_requested_theme(fake: FakeClient) -> None:
    fake.replies.append(
        reply(
            {
                "questions": [
                    _iq("Why do you travel?", theme="Trips"),
                    _iq("What did a trip teach you?", seconds=200),
                ]
            }
        )
    )
    result = generate_questions(
        count=2,
        category=None,
        exclude=[],
        track="interests",
        language="en",
        interests=_context(theme="Travel"),
    )
    assert result == {
        "source": "claude",
        "questions": [
            {
                "text": "Why do you travel?",
                "category": "interest",
                "theme": "Travel",
                "target_seconds": 60,
            },
            {
                "text": "What did a trip teach you?",
                "category": "interest",
                "theme": "Travel",
                "target_seconds": 120,
            },
        ],
    }


def test_any_theme_takes_his_spelling_of_the_theme_claude_names(fake: FakeClient) -> None:
    fake.replies.append(reply({"questions": [_iq("What is joy?", theme="happiness", seconds=10)]}))
    result = generate_questions(
        count=1,
        category=None,
        exclude=[],
        track="interests",
        language="en",
        interests=_context(),
    )
    assert result["questions"] == [
        {"text": "What is joy?", "category": "interest", "theme": "Happiness", "target_seconds": 60}
    ]


def test_too_few_usable_interest_questions_fall_back_to_the_bank(fake: FakeClient) -> None:
    fake.replies.append(reply({"questions": [_iq("Why travel?"), _iq("why  travel?")]}))
    result = generate_questions(
        count=2,
        category=None,
        exclude=[],
        track="interests",
        language="en",
        interests=_context(theme="Travel"),
    )
    assert result["source"] == "bank"
    assert len(result["questions"]) == 2


def test_an_api_error_falls_back_to_the_interest_bank(fake: FakeClient) -> None:
    fake.replies.append(
        anthropic.APIConnectionError(request=httpx2.Request("POST", "https://example.test"))
    )
    result = generate_questions(
        count=3,
        category=None,
        exclude=[],
        track="interests",
        language="zh",
        interests=_context(),
    )
    assert result["source"] == "bank"
    assert all(q["category"] == "interest" for q in result["questions"])


def test_chinese_work_questions_ask_claude_for_chinese(fake: FakeClient) -> None:
    fake.replies.append(
        reply(
            {
                "questions": [
                    {"text": "为什么选 Kafka？", "category": "decision", "target_seconds": 90}
                ]
            }
        )
    )
    result = generate_questions(count=1, category="decision", exclude=[], language="zh")
    assert result["questions"][0]["text"] == "为什么选 Kafka？"
    user = fake.calls[0]["messages"][0]["content"][0]["text"]
    assert "Write the questions in Simplified Chinese." in user


# -- themes ------------------------------------------------------------------------------------


def test_theme_names_are_short_unique_and_never_removed_ones() -> None:
    names = [
        " Happiness ",
        "happiness",
        "Travel",
        "The meaning of a good life",
        "Courage",
        "",
        "Charisma",
        "Time",
        "Money",
        "Family",
        "Learning",
    ]
    assert clean_names(names, hidden=["courage"]) == [
        "Happiness",
        "Travel",
        "Charisma",
        "Time",
        "Money",
        "Family",
    ]


def test_learning_returns_the_cleaned_themes(fake: FakeClient) -> None:
    fake.replies.append(reply({"themes": ["Happiness", "Courage", "Travel"]}))
    names = learn_themes(
        topics=[{"text": "被讨厌的勇气", "language": "zh"}],
        current=["Happiness"],
        hidden=["Courage"],
    )
    assert names == ["Happiness", "Travel"]
    assert fake.options == [{"timeout": 30.0, "max_retries": 1}]
    user = fake.calls[0]["messages"][0]["content"][0]["text"]
    assert "[zh] 被讨厌的勇气" in user
    assert "<removed_themes>\nCourage\n</removed_themes>" in user


def test_learning_without_a_key_or_with_a_failure_gives_none(
    no_key: None, monkeypatch: pytest.MonkeyPatch
) -> None:
    assert learn_themes(topics=[], current=[], hidden=[]) is None
    client = FakeClient(reply("not json"))
    monkeypatch.setattr(claude_mod, "api_key", lambda: "test-key")
    monkeypatch.setattr(claude_mod, "client", lambda: client)
    assert learn_themes(topics=[], current=[], hidden=[]) is None
