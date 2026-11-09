"""coach_take and coaching_info against a fake Anthropic client. No network."""

from __future__ import annotations

import copy
import re

import anthropic
import httpx2
import pytest
from coaching_helpers import (
    FakeClient,
    coaching_example,
    comparison_example,
    output_example,
    reply,
    request,
    retry_output,
    retry_request,
)

from speakup.coaching import (
    CoachingFailed,
    CoachingUnavailable,
    coach_take,
    coaching_info,
)
from speakup.coaching import claude as claude_mod


@pytest.fixture
def fake(monkeypatch: pytest.MonkeyPatch):
    """Install a fake client with a key present; tests queue replies on it."""
    client = FakeClient()
    monkeypatch.setattr(claude_mod, "api_key", lambda: "test-key")
    monkeypatch.setattr(claude_mod, "model", lambda: "claude-opus-5-5")
    monkeypatch.setattr(claude_mod, "client", lambda: client)
    return client


def _without_created_at(report: dict) -> dict:
    return {k: v for k, v in report.items() if k != "created_at"}


def test_valid_output_becomes_the_contract_report(fake: FakeClient) -> None:
    fake.replies.append(reply(output_example()))

    report = coach_take(request())

    assert _without_created_at(report) == _without_created_at(coaching_example())
    assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z", report["created_at"])
    assert list(report) == list(coaching_example())  # key order matches the contract
    assert len(fake.calls) == 1


def test_anchor_times_come_from_the_words(fake: FakeClient) -> None:
    fake.replies.append(reply(output_example()))

    report = coach_take(request())

    assert report["strength"]["anchor"] == {
        "quote": "we picked Postgres because",
        "word_start": 4,
        "word_end": 8,
        "start": 2.45,
        "end": 3.9,
    }
    assert report["focus"][1]["evidence"][0]["start"] == 3.55
    assert report["focus"][1]["evidence"][0]["end"] == 5.4


def test_wrong_range_is_repaired_from_the_quote(fake: FakeClient) -> None:
    output = output_example()
    output["strength"]["anchor"]["word_start"] = 3
    output["strength"]["anchor"]["word_end"] = 6
    fake.replies.append(reply(output))

    report = coach_take(request())

    anchor = report["strength"]["anchor"]
    assert (anchor["word_start"], anchor["word_end"]) == (4, 8)
    assert (anchor["start"], anchor["end"]) == (2.45, 3.9)
    assert len(fake.calls) == 1


def test_invalid_output_is_reasked_once_with_the_errors(fake: FakeClient) -> None:
    bad = output_example()
    bad["focus"][0]["evidence"][0]["quote"] = "the queries were slow"
    fake.replies += [reply(bad), reply(output_example())]

    report = coach_take(request())

    assert _without_created_at(report) == _without_created_at(coaching_example())
    assert len(fake.calls) == 2
    first, second = fake.calls
    assert first["system"] == second["system"]
    blocks = second["messages"][0]["content"]
    assert len(blocks) == 2
    assert blocks[0] == first["messages"][0]["content"][0]
    assert "focus[0].evidence[0]" in blocks[1]["text"]
    assert "the queries were slow" in blocks[1]["text"]


def test_invalid_twice_raises_coaching_failed(fake: FakeClient) -> None:
    bad = output_example()
    bad["filler_rulings"] = []
    fake.replies += [reply(bad), reply(bad)]

    with pytest.raises(CoachingFailed, match="missing rulings for e2"):
        coach_take(request())
    assert len(fake.calls) == 2


def test_unparseable_output_is_reasked(fake: FakeClient) -> None:
    fake.replies += [reply("{not json"), reply(output_example())]

    coach_take(request())

    assert len(fake.calls) == 2


def test_truncated_output_is_reasked_then_fails(fake: FakeClient) -> None:
    fake.replies += [reply("{", stop_reason="max_tokens"), reply("{", stop_reason="max_tokens")]

    with pytest.raises(CoachingFailed, match="token limit"):
        coach_take(request())


def test_refusal_fails_without_reask(fake: FakeClient) -> None:
    fake.replies.append(reply("", stop_reason="refusal"))

    with pytest.raises(CoachingFailed, match="refusal"):
        coach_take(request())
    assert len(fake.calls) == 1


def test_api_error_becomes_coaching_failed(fake: FakeClient) -> None:
    error = anthropic.APIConnectionError(
        request=httpx2.Request("POST", "https://api.anthropic.com/v1/messages")
    )
    fake.replies.append(error)

    with pytest.raises(CoachingFailed, match="APIConnectionError"):
        coach_take(request())


def test_missing_key_is_unavailable(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(claude_mod, "api_key", lambda: None)

    def no_client():
        raise AssertionError("no client without a key")

    monkeypatch.setattr(claude_mod, "client", no_client)

    with pytest.raises(CoachingUnavailable):
        coach_take(request())
    info = coaching_info()
    assert info["available"] is False
    assert info["rubric_version"] == "rubric/1"
    assert info["prompt_version"] == "coach-prompt/1"


def test_coaching_info_with_key(fake: FakeClient) -> None:
    assert coaching_info() == {
        "available": True,
        "model": "claude-opus-5-5",
        "rubric_version": "rubric/1",
        "prompt_version": "coach-prompt/1",
    }


def test_served_model_is_recorded(fake: FakeClient) -> None:
    """A refusal fallback serves the request on another model; the report says which."""
    fake.replies.append(reply(output_example(), model="claude-opus-4-8"))

    assert coach_take(request())["model"] == "claude-opus-4-8"


def test_first_take_comparison_is_null_even_if_returned(fake: FakeClient) -> None:
    output = output_example()
    output["comparison"] = retry_output()["comparison"]
    fake.replies.append(reply(output))

    assert coach_take(request())["comparison"] is None


def test_retry_sends_previous_take_and_returns_comparison(fake: FakeClient) -> None:
    fake.replies.append(reply(retry_output()))

    report = coach_take(retry_request())

    user = fake.calls[0]["messages"][0]["content"][0]["text"]
    assert '<previous_take attempt="1">' in user
    assert "Focus 0 (layering): Number your reasons." in user
    assert "Focus 1 (fluency): Stop silently, not mid-phrase." in user
    assert "So um we nee- we picked Postgres" in user  # the previous transcript
    assert "one outcome for each of the 2 previous focus items" in user
    assert report["comparison"] == comparison_example()


def test_retry_without_comparison_is_reasked(fake: FakeClient) -> None:
    missing = retry_output()
    missing["comparison"] = None
    fake.replies += [reply(missing), reply(retry_output())]

    report = coach_take(retry_request())

    assert "comparison: this is a retry" in fake.calls[1]["messages"][0]["content"][1]["text"]
    assert report["comparison"] == comparison_example()


def test_retry_outcomes_must_cover_each_previous_focus(fake: FakeClient) -> None:
    partial = retry_output()
    partial["comparison"]["focus_outcomes"] = partial["comparison"]["focus_outcomes"][:1]
    fake.replies += [reply(partial), reply(partial)]

    with pytest.raises(CoachingFailed, match="exactly one outcome for each previous focus"):
        coach_take(retry_request())


def test_retry_with_uncoached_previous_take_has_no_comparison(fake: FakeClient) -> None:
    req = retry_request()
    req["previous"]["coaching"] = None
    output = retry_output()
    output["comparison"] = None
    fake.replies.append(reply(output))

    report = coach_take(req)

    user = fake.calls[0]["messages"][0]["content"][0]["text"]
    assert '<previous_take attempt="1">' in user
    assert "<previous_focus>" not in user
    assert "comparison is null" in user
    assert report["comparison"] is None


def test_request_is_not_mutated(fake: FakeClient) -> None:
    req = request()
    before = copy.deepcopy(req)
    fake.replies.append(reply(output_example()))

    coach_take(req)

    assert req == before
