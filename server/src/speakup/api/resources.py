"""Turn store rows into the resources the API serves, and compose the comparison."""

from __future__ import annotations

import json
from typing import Any

Row = dict[str, Any]

DIMENSIONS = ("answer_first", "layering", "focus", "concision", "fluency", "close")
_LEVEL_RANK = {"needs_work": 0, "okay": 1, "strong": 2}


def session_resource(row: Row) -> Row:
    return {
        "id": row["id"],
        "mode": row["mode"],
        "started_at": row["started_at"],
        "ended_at": row["ended_at"],
        "nervousness_before": row["nervousness_before"],
        "nervousness_after": row["nervousness_after"],
        "created_at": row["created_at"],
        "updated_at": row["updated_at"],
    }


def prompt_resource(row: Row) -> Row:
    return {
        "id": row["id"],
        "session_id": row["session_id"],
        "kind": row["kind"],
        "text": row["text"],
        "notes": row["notes"],
        "category": row["category"],
        "target_seconds": row["target_seconds"],
        "question_source": row["question_source"],
        "created_at": row["created_at"],
    }


def take_resource(row: Row) -> Row:
    error = None
    if row["error_code"] is not None:
        error = {"code": row["error_code"], "message": row["error_message"]}
    summary = None
    if row["status"] == "done":
        titles = row["s_focus_titles"]
        summary = {
            "verdict": row["s_verdict"],
            "focus_titles": json.loads(titles) if titles else [],
            "fillers_per_100_words": row["s_fillers"],
            "blocks": row["s_blocks"],
            "restarts": row["s_restarts"],
            "wpm_voiced": row["s_wpm"],
        }
    return {
        "id": row["id"],
        "prompt_id": row["prompt_id"],
        "session_id": row["session_id"],
        "attempt": row["attempt"],
        "recorded_at": row["recorded_at"],
        "duration_s": row["duration_s"],
        "mic_route": row["mic_route"],
        "status": row["status"],
        "status_changed_at": row["status_changed_at"],
        "coaching_status": row["coaching_status"],
        "previous_take_id": row["previous_take_id"],
        "error": error,
        "summary": summary,
        "created_at": row["created_at"],
        "updated_at": row["updated_at"],
    }


def compose_comparison(
    *,
    take: Row,
    previous: Row,
    coaching: Row | None,
    previous_coaching: Row | None,
    metric_changes: list[Row],
) -> Row:
    """The Comparison document. The coaching-based parts are empty unless both takes have a
    coaching report."""
    comparison = (coaching or {}).get("comparison")
    summary = comparison["summary"] if comparison else None
    focus_outcomes: list[Row] = []
    dimension_changes: list[Row] = []
    if coaching is not None and previous_coaching is not None:
        outcomes = {
            o["previous_focus_index"]: o for o in (comparison or {}).get("focus_outcomes", [])
        }
        for index, focus in enumerate(previous_coaching["focus"]):
            outcome = outcomes.get(index)
            if outcome is None:
                continue
            focus_outcomes.append(
                {
                    "title": focus["title"],
                    "dimension": focus["dimension"],
                    "outcome": outcome["outcome"],
                    "evidence": outcome["evidence"],
                    "anchor": outcome["anchor"],
                }
            )
        for dimension in DIMENSIONS:
            before = previous_coaching["dimensions"][dimension]["level"]
            after = coaching["dimensions"][dimension]["level"]
            delta = _LEVEL_RANK.get(after, 1) - _LEVEL_RANK.get(before, 1)
            dimension_changes.append(
                {
                    "dimension": dimension,
                    "before": before,
                    "after": after,
                    "change": "better" if delta > 0 else "worse" if delta < 0 else "same",
                }
            )
    return {
        "take_id": take["id"],
        "previous_take_id": previous["id"],
        "attempt": take["attempt"],
        "previous_attempt": previous["attempt"],
        "coaching_status": take["coaching_status"],
        "summary": summary,
        "focus_outcomes": focus_outcomes,
        "dimension_changes": dimension_changes,
        "metric_changes": metric_changes,
    }
