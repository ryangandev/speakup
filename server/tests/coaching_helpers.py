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


# ---------------------------------------------------------------------------
# A Mandarin take, analyzed from a hand-made token list


ZH_QUESTION = "账单服务为什么选了 Postgres，而不是 DynamoDB？"
# One token per character, punctuation attached, as a Mandarin engine writes it. It has filled
# pauses, lexical candidates, a repetition (我我, 就是就是) and a 1.2 s block inside a phrase.
ZH_SCRIPT = (
    "嗯 |0.4| 我 们 最 后 选 了 Postgres， 没 有 选 DynamoDB。 主 要 是 两 个 原 因。 "
    "第 一， 那 个 |0.5| 账 单 服 务 需 要 很 多 关 联 查 询， 我 我 觉 得 用 Postgres 写 起 来 "
    "简 单 很 多。 然 后 第 二 个 原 因 是 |1.2| 团 队 其 实 对 Postgres 更 熟 悉， 出 了 问 题 "
    "能 很 快 定 位。 就 是 就 是 说， 成 本 上 也 差 不 多。 呃 |0.6| 当 然 DynamoDB 扩 展 性 更 "
    "好， 但 是 我 们 现 在 的 量 还 用 不 到。 所 以 结 论 就 是 先 用 Postgres， "
    "以 后 量 大 了 再 看 看。"
)


def zh_analysis() -> dict[str, Any]:
    from analysis_helpers import analyze_zh

    analysis = analyze_zh(ZH_SCRIPT)
    analysis["take_id"] = "3b9f6a52-7c1d-4e8a-9f0b-2d4c6e8a0b1c"
    return analysis


def zh_request(**overrides: Any) -> dict[str, Any]:
    analysis = zh_analysis()
    req = request(
        take_id=analysis["take_id"],
        prompt={
            "kind": "impromptu",
            "text": ZH_QUESTION,
            "notes": None,
            "category": "decision",
            "target_seconds": 60,
            "language": "zh",
        },
        analysis=analysis,
    )
    req.update(overrides)
    return req


def zh_anchor(analysis: dict[str, Any], quote: str) -> dict[str, Any]:
    """An anchor for `quote`, at the first word range whose characters match it."""
    from speakup.coaching.validate import Transcript, tokens

    (start, end), *_ = Transcript(analysis["words"]).find(tokens(quote))
    return {"quote": quote, "word_start": start, "word_end": end}


def zh_output(analysis: dict[str, Any]) -> dict[str, Any]:
    """A valid Chinese coaching output for `zh_analysis()`."""
    lexical = [e["id"] for e in analysis["events"] if e["type"] == "lexical_filler"]
    level = {"level": "okay", "evidence": "结构基本清楚。"}
    return {
        "verdict": "结论放在了开头，两个原因也编了号，但中间卡顿和重复让第二个原因听起来没底气。",
        "strength": {
            "dimension": "answer_first",
            "point": "第一句就给出了选择，听的人马上知道答案。",
            "anchor": zh_anchor(analysis, "我们最后选了Postgres"),
        },
        "focus": [
            {
                "dimension": "fluency",
                "title": "停在句子之间",
                "problem": "你在“原因是”后面停了一秒多，句子被切断。",
                "evidence": [zh_anchor(analysis, "第二个原因是")],
                "instruction": "想好整句再开口：先在心里说完“第二，团队更熟悉”，再说出来。",
            }
        ],
        "dimensions": {
            "answer_first": {"level": "strong", "evidence": "第一句就是结论。"},
            "layering": {"level": "strong", "evidence": "两个原因有编号。"},
            "focus": level,
            "concision": level,
            "fluency": {"level": "needs_work", "evidence": "一次一秒以上的卡顿。"},
            "close": {"level": "strong", "evidence": "最后重申了结论。"},
        },
        "outline": {
            "main_point": "账单服务选了 Postgres。",
            "main_point_first": True,
            "points": [
                {"summary": "选了 Postgres", "role": "main", "word_start": 1, "word_end": 12},
            ],
        },
        "reference_version": {
            "text": "我们选了 Postgres，有两个原因。\n\n第一，账单需要很多关联查询。",
            "structure": "结论，两个编号的原因，结论。",
        },
        "filler_rulings": [{"event_id": i, "is_filler": True} for i in lexical],
        "annotations": [],
        "comparison": None,
    }
