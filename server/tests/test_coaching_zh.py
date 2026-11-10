"""Coaching a Mandarin take: the request (snapshots), quote matching without spaces, the
report's prompt version, a retry, and the developer command's --language."""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from coaching_helpers import (
    ZH_QUESTION,
    FakeClient,
    reply,
    request,
    zh_analysis,
    zh_anchor,
    zh_output,
    zh_request,
)
from test_coaching_request import _split, assert_snapshot

from speakup.coaching import claude as claude_mod
from speakup.coaching import coach_take
from speakup.coaching.__main__ import main
from speakup.coaching.models import Anchor
from speakup.coaching.prompt import plain_transcript, system_prompt
from speakup.coaching.validate import Transcript, check_anchor, tokens, validate_output


@pytest.fixture
def fake(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> FakeClient:
    client = FakeClient()
    monkeypatch.setattr(claude_mod, "api_key", lambda: "test-key")
    monkeypatch.setattr(claude_mod, "model", lambda: "claude-opus-5-5")
    monkeypatch.setattr(claude_mod, "client", lambda: client)
    monkeypatch.setattr(claude_mod, "data_dir", lambda: tmp_path)
    return client


def test_mandarin_request(fake: FakeClient) -> None:
    analysis = zh_analysis()
    fake.replies.append(reply(zh_output(analysis)))
    report = coach_take(zh_request())

    system, user, _, _ = _split(fake.calls[0])
    assert system.startswith(system_prompt("en"))
    assert_snapshot("coach_system_zh.md", system)
    assert_snapshot("coach_user_zh.txt", user[0] + "\n")
    assert "Language: Mandarin Chinese" in user[0]
    assert "characters." in user[0] and "per 100 characters" in user[0]
    assert report["prompt_version"] == "coach-prompt/1+coach-zh/1"
    assert report["strength"]["anchor"]["quote"] == "我们最后选了Postgres"


def test_english_request_has_no_mandarin_addition(fake: FakeClient) -> None:
    from coaching_helpers import output_example

    fake.replies.append(reply(output_example()))
    report = coach_take(request())
    system, user, _, _ = _split(fake.calls[0])
    assert system == system_prompt()
    assert "Mandarin" not in system + user[0]
    assert report["prompt_version"] == "coach-prompt/1"


def test_tokens_split_han_characters_and_ignore_full_width_punctuation() -> None:
    assert tokens("我们，选了 Postgres。") == ["我", "们", "选", "了", "postgres"]
    assert tokens("“就是”……") == ["就", "是"]


def _words(*texts: str) -> list[dict]:
    return [
        {"i": i, "text": t, "start": i * 0.25, "end": i * 0.25 + 0.2} for i, t in enumerate(texts)
    ]


def test_a_chinese_quote_matches_without_spaces_whatever_the_token_split() -> None:
    transcript = Transcript(_words("我们", "选", "了", "Postgres，", "因", "为", "好", "用。"))
    exact = Anchor(quote="我们选了Postgres", word_start=0, word_end=4)
    assert check_anchor(exact, transcript, "a") is None
    spaced = Anchor(quote="我们选了 Postgres，", word_start=0, word_end=4)
    assert check_anchor(spaced, transcript, "a") is None
    wrong = Anchor(quote="因为好用", word_start=1, word_end=3)
    assert check_anchor(wrong, transcript, "a") is None
    assert (wrong.word_start, wrong.word_end) == (4, 8)
    missing = Anchor(quote="团队熟悉", word_start=0, word_end=2)
    assert "does not appear" in check_anchor(missing, transcript, "a")
    # Half of a multi-character token is not a whole-word range.
    half = Anchor(quote="们选了", word_start=0, word_end=3)
    assert check_anchor(half, transcript, "a") is not None


def test_a_valid_chinese_output_validates_and_a_translated_quote_does_not() -> None:
    analysis = zh_analysis()
    lexical = [e["id"] for e in analysis["events"] if e["type"] == "lexical_filler"]
    output = zh_output(analysis)
    parsed, errors = validate_output(
        json.dumps(output),
        words=analysis["words"],
        lexical_filler_ids=lexical,
        previous_focus_count=None,
    )
    assert errors == [] and parsed is not None

    output["focus"][0]["evidence"] = [
        {"quote": "the second reason is", "word_start": 0, "word_end": 4}
    ]
    _, errors = validate_output(
        json.dumps(output),
        words=analysis["words"],
        lexical_filler_ids=lexical,
        previous_focus_count=None,
    )
    assert any("does not appear" in e for e in errors)


def test_a_mandarin_retry_shows_the_previous_transcript_as_running_text(fake: FakeClient) -> None:
    analysis = zh_analysis()
    previous_report = {**zh_output(analysis), "take_id": analysis["take_id"]}
    current = zh_analysis()
    current["take_id"] = "8d7c6b5a-4f3e-4d2c-9b1a-0f9e8d7c6b5a"
    output = zh_output(current)
    output["comparison"] = {
        "summary": "卡顿少了。",
        "focus_outcomes": [
            {
                "previous_focus_index": 0,
                "outcome": "not_improved",
                "evidence": "还是在同一处停了一秒多。",
                "anchor": zh_anchor(current, "第二个原因是"),
            }
        ],
    }
    fake.replies.append(reply(output))
    report = coach_take(
        zh_request(
            take_id=current["take_id"],
            attempt=2,
            analysis=current,
            previous={"attempt": 1, "analysis": analysis, "coaching": previous_report},
        )
    )
    _, user, _, _ = _split(fake.calls[0])
    assert plain_transcript(analysis["words"], "zh") in user[0]
    assert "我们最后选了Postgres，没有选DynamoDB。" in user[0]
    assert report["comparison"]["focus_outcomes"][0]["anchor"]["quote"] == "第二个原因是"


def test_cli_language_flag_and_default(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture, tmp_path: Path
) -> None:
    monkeypatch.setattr(claude_mod, "api_key", lambda: None)
    analysis = zh_analysis()
    path = tmp_path / "zh.json"
    path.write_text(json.dumps(analysis, ensure_ascii=False), encoding="utf-8")

    assert main([str(path), "--prompt", ZH_QUESTION, "--dry-run"]) == 0
    assert "# Mandarin takes" in capsys.readouterr().out

    assert main([str(path), "--prompt", ZH_QUESTION, "--language", "en", "--dry-run"]) == 0
    assert "# Mandarin takes" not in capsys.readouterr().out
