"""Fixtures and a fake Anthropic client for the coaching tests.

The analysis and coaching examples in tests/fixtures/coaching are copied from
docs/architecture.md. The analysis example lists only its first 18 words, while the
coaching example points at words up to 214, so `analysis_example()` pads the word list
with plain words to the length the example's metrics imply.
"""

from __future__ import annotations

import copy
import json
from pathlib import Path
from types import SimpleNamespace
from typing import Any

FIXTURES = Path(__file__).parent / "fixtures" / "coaching"
TOTAL_WORDS = 219  # 214 counted words plus 5 filled pauses

_PAD_TEXT = (
    "and the team also knows Postgres much better than Dynamo which matters when "
    "something breaks at night so we can fix it fast"
)
_PAD = _PAD_TEXT.split()

QUESTION = "Why did we choose Postgres over DynamoDB for the billing service?"


def load(name: str) -> Any:
    return json.loads((FIXTURES / name).read_text(encoding="utf-8"))


def _pad(words: list[dict[str, Any]], total: int) -> list[dict[str, Any]]:
    t = words[-1]["end"]
    k = 0
    while len(words) < total:
        text = _PAD[k % len(_PAD)]
        t = round(t + 0.1, 2)
        end = round(t + 0.25, 2)
        words.append(
            {
                "i": len(words),
                "text": text,
                "norm": text.lower(),
                "start": t,
                "end": end,
                "confidence": 0.98,
                "kind": "word",
                "cutoff": False,
            }
        )
        t = end
        k += 1
    return words


def analysis_example() -> dict[str, Any]:
    """The rules-only analysis of the example take (attempt 1)."""
    analysis = load("analysis_example.json")
    analysis["words"] = _pad(analysis["words"], TOTAL_WORDS)
    return analysis


def coaching_example() -> dict[str, Any]:
    """The stored coaching report of the example take."""
    return load("coaching_example.json")


def comparison_example() -> dict[str, Any]:
    return load("comparison_example.json")


def strip_report(report: dict[str, Any]) -> dict[str, Any]:
    """The coaching output Claude would have returned for a stored report."""
    out = copy.deepcopy(report)
    for key in (
        "schema_version",
        "take_id",
        "created_at",
        "model",
        "rubric_version",
        "prompt_version",
    ):
        out.pop(key)

    def bare(anchor: dict[str, Any] | None) -> dict[str, Any] | None:
        if anchor is None:
            return None
        return {k: anchor[k] for k in ("quote", "word_start", "word_end")}

    out["strength"]["anchor"] = bare(out["strength"]["anchor"])
    for item in out["focus"]:
        item["evidence"] = [bare(a) for a in item["evidence"]]
    if out["comparison"]:
        for outcome in out["comparison"]["focus_outcomes"]:
            outcome["anchor"] = bare(outcome["anchor"])
    return out


def output_example() -> dict[str, Any]:
    return strip_report(coaching_example())


def _word(i: int, text: str, start: float, end: float, kind: str = "word") -> dict[str, Any]:
    return {
        "i": i,
        "text": text,
        "norm": text.lower().strip(".,"),
        "start": start,
        "end": end,
        "confidence": 0.97,
        "kind": kind,
        "cutoff": False,
    }


def retry_analysis() -> dict[str, Any]:
    """Attempt 2 of the same prompt, shaped so the contract's comparison anchor
    ("Two reasons. First," at words 6 to 9, 2.1 s to 3.0 s) holds."""
    spec = [
        ("We", 0.6, 0.75),
        ("chose", 0.8, 1.0),
        ("Postgres", 1.05, 1.4),
        ("for", 1.45, 1.55),
        ("the", 1.58, 1.65),
        ("billing.", 1.7, 2.0),
        ("Two", 2.1, 2.3),
        ("reasons.", 2.35, 2.7),
        ("First,", 2.75, 3.0),
        ("reporting", 3.3, 3.7),
        ("needs", 3.75, 3.95),
        ("joins.", 4.0, 4.4),
        ("Second,", 4.9, 5.3),
        ("like,", 5.4, 5.6),
        ("invoices", 5.7, 6.2),
        ("need", 6.25, 6.45),
        ("transactions.", 6.5, 7.2),
    ]
    words = [_word(i, text, s, e) for i, (text, s, e) in enumerate(spec)]
    analysis = copy.deepcopy(load("analysis_example.json"))
    analysis["take_id"] = "e98b1f37-2a4c-4d1e-9f60-6b5c8a0d3e21"
    analysis["words"] = _pad(words, 160)
    analysis["events"] = [
        {
            "id": "e0",
            "type": "lexical_filler",
            "start": 5.4,
            "end": 5.6,
            "word_start": 13,
            "word_end": 14,
            "source": "rules",
            "reason": None,
            "repair_word": None,
            "is_filler": True,
            "filler_resolution": "rules",
            "note": None,
        },
    ]
    analysis["metrics"]["word_count"] = 160
    analysis["metrics"]["blocks"] = {
        "count": 1,
        "per_minute": 0.8,
        "longest_s": 0.6,
        "total_s": 0.6,
    }
    analysis["nervousness_signs"] = []
    return analysis


def retry_output() -> dict[str, Any]:
    """A valid coaching output for `retry_analysis()`, with the contract's comparison."""
    out = output_example()
    out["strength"]["anchor"] = {"quote": "We chose Postgres", "word_start": 0, "word_end": 3}
    out["focus"] = [out["focus"][0]]
    out["focus"][0]["evidence"] = [
        {"quote": "Second, like, invoices", "word_start": 12, "word_end": 15}
    ]
    out["outline"]["points"] = [
        {"summary": "Chose Postgres", "role": "main", "word_start": 0, "word_end": 6},
        {"summary": "Reporting needs joins", "role": "support", "word_start": 6, "word_end": 12},
        {
            "summary": "Invoices need transactions",
            "role": "support",
            "word_start": 12,
            "word_end": 17,
        },
    ]
    out["filler_rulings"] = [{"event_id": "e0", "is_filler": True}]
    out["annotations"] = []
    out["comparison"] = strip_report({**coaching_example(), "comparison": comparison_example()})[
        "comparison"
    ]
    return out


def request(**overrides: Any) -> dict[str, Any]:
    """The coaching request for the example take."""
    req: dict[str, Any] = {
        "take_id": "c41a7e02-5b9d-4c66-8e1f-0a7b3d92f5c4",
        "mode": "home",
        "prompt": {
            "kind": "impromptu",
            "text": QUESTION,
            "notes": None,
            "category": "decision",
            "target_seconds": 90,
        },
        "attempt": 1,
        "analysis": analysis_example(),
        "previous": None,
    }
    req.update(overrides)
    return req


def retry_request() -> dict[str, Any]:
    previous_analysis = analysis_example()
    return request(
        take_id="e98b1f37-2a4c-4d1e-9f60-6b5c8a0d3e21",
        attempt=2,
        analysis=retry_analysis(),
        previous={"attempt": 1, "analysis": previous_analysis, "coaching": coaching_example()},
    )


# ---------------------------------------------------------------------------
# Fake Anthropic client


def reply(
    payload: Any, *, stop_reason: str = "end_turn", model: str = "claude-opus-5-5"
) -> SimpleNamespace:
    text = payload if isinstance(payload, str) else json.dumps(payload)
    return SimpleNamespace(
        content=[
            SimpleNamespace(type="thinking", thinking="", signature="sig"),
            SimpleNamespace(type="text", text=text),
        ],
        model=model,
        stop_reason=stop_reason,
        usage=SimpleNamespace(
            input_tokens=9000,
            output_tokens=3000,
            cache_read_input_tokens=0,
            cache_creation_input_tokens=0,
        ),
    )


class FakeClient:
    """Records each `beta.messages.create` call and returns queued replies in order."""

    def __init__(self, *replies: Any) -> None:
        self.replies = list(replies)
        self.calls: list[dict[str, Any]] = []
        self.beta = SimpleNamespace(messages=SimpleNamespace(create=self._create))

    def _create(self, **kwargs: Any) -> Any:
        self.calls.append(kwargs)
        if not self.replies:
            raise AssertionError("FakeClient got an unexpected call")
        item = self.replies.pop(0)
        if isinstance(item, BaseException):
            raise item
        return item
