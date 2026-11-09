"""The developer command `python -m speakup.coaching`."""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from coaching_helpers import (
    QUESTION,
    FakeClient,
    analysis_example,
    coaching_example,
    reply,
    retry_analysis,
    retry_output,
)

from speakup.coaching import claude as claude_mod
from speakup.coaching.__main__ import main


@pytest.fixture
def files(tmp_path: Path) -> dict[str, str]:
    paths = {
        "analysis": tmp_path / "a1.json",
        "retry": tmp_path / "a2.json",
        "report": tmp_path / "r1.json",
    }
    paths["analysis"].write_text(json.dumps(analysis_example()))
    paths["retry"].write_text(json.dumps(retry_analysis()))
    paths["report"].write_text(json.dumps(coaching_example()))
    return {k: str(v) for k, v in paths.items()}


def test_dry_run_needs_no_key(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture, files: dict
) -> None:
    monkeypatch.setattr(claude_mod, "api_key", lambda: None)

    code = main([files["analysis"], "--prompt", QUESTION, "--category", "decision", "--dry-run"])

    out = capsys.readouterr().out
    assert code == 0
    assert "You are the speaking coach inside SpeakUp" in out
    assert f"Question: {QUESTION}" in out


def test_missing_key_exits_with_a_hint(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture, files: dict
) -> None:
    monkeypatch.setattr(claude_mod, "api_key", lambda: None)

    assert main([files["analysis"]]) == 2
    assert "ANTHROPIC_API_KEY" in capsys.readouterr().err


def test_retry_prints_the_report(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture, files: dict
) -> None:
    fake = FakeClient(reply(retry_output()))
    monkeypatch.setattr(claude_mod, "api_key", lambda: "test-key")
    monkeypatch.setattr(claude_mod, "model", lambda: "claude-opus-5-5")
    monkeypatch.setattr(claude_mod, "client", lambda: fake)

    code = main(
        [
            files["retry"],
            "--prompt",
            QUESTION,
            "--previous",
            files["analysis"],
            "--previous-report",
            files["report"],
        ]
    )

    captured = capsys.readouterr()
    assert code == 0
    report = json.loads(captured.out)
    assert report["comparison"]["focus_outcomes"][0]["outcome"] == "improved"
    assert "usage" in captured.err
    user = fake.calls[0]["messages"][0]["content"][0]["text"]
    assert "Attempt: 2" in user
    assert '<previous_take attempt="1">' in user
