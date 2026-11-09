"""Finalization (coaching applied to the rules-only analysis) and metric comparison.

Both are pure: they never change their inputs. See docs/architecture.md#finalization and
#comparison.
"""

from __future__ import annotations

import copy
from typing import Any

from speakup.analysis.events import event, sort_key
from speakup.analysis.metrics import event_metrics

AnalysisDoc = dict[str, Any]
CoachingReportDoc = dict[str, Any]
MetricChange = dict[str, Any]

ANNOTATION_REASONS = {"off_topic": None, "restart": "self_correction"}


def finalize(analysis: AnalysisDoc, coaching: CoachingReportDoc | None) -> AnalysisDoc:
    """Apply the coaching report's filler rulings and annotations, then recompute the metrics
    that count events. Expects the rules-only stage output; raises ValueError when the report
    does not fit the analysis, since coaching validates its output against it."""
    if analysis.get("coaching_applied"):
        raise ValueError("finalize expects the rules-only analysis, not a finalized one")
    doc = copy.deepcopy(analysis)
    if coaching is None:
        doc["coaching_applied"] = False
        return doc

    events = doc["events"]
    by_id = {e["id"]: e for e in events}
    for ruling in coaching.get("filler_rulings", []):
        target = by_id.get(ruling["event_id"])
        if target is None or target["type"] != "lexical_filler":
            raise ValueError(f"filler ruling for unknown lexical filler {ruling['event_id']!r}")
        target["is_filler"] = bool(ruling["is_filler"])
        target["filler_resolution"] = "coaching"

    words = doc["words"]
    for n, note in enumerate(coaching.get("annotations", [])):
        start, end = note["word_start"], note["word_end"]
        if note["type"] not in ANNOTATION_REASONS:
            raise ValueError(f"unknown annotation type {note['type']!r}")
        if not 0 <= start < end <= len(words):
            raise ValueError(f"annotation word range {start}..{end} is outside the transcript")
        added = event(
            note["type"],
            words[start]["start"],
            words[end - 1]["end"],
            start,
            end,
            source="coaching",
            reason=ANNOTATION_REASONS[note["type"]],
            note=note.get("note"),
        )
        added["id"] = f"c{n}"
        events.append(added)
    events.sort(key=sort_key)

    metrics = doc["metrics"]
    metrics.update(
        event_metrics(events, metrics["word_count"], metrics["speaking_s"], coached=True)
    )
    doc["coaching_applied"] = True
    return doc


# (metric, label, unit, path in metrics, graded, kind) in the order the contract fixes.
_COMPARED = [
    ("fillers_per_100_words", "Fillers per 100 words", "per 100 words",
     ("fillers", "per_100_words"), True, "rate"),
    ("blocks", "Blocks", "count", ("blocks", "count"), True, "count"),
    ("restarts", "Restarts", "count", ("restarts",), True, "count"),
    ("repetitions", "Repetitions", "count", ("repetitions",), True, "count"),
    ("wpm_voiced", "Pace", "words per minute", ("pace", "wpm_voiced"), False, "info"),
    ("duration_s", "Length", "seconds", ("duration_s",), False, "info"),
    ("pitch_variation_st", "Pitch variation", "semitones", ("pitch", "variation_st"), False,
     "info"),
    ("volume_variation_db", "Volume variation", "dB", ("volume", "variation_db"), False, "info"),
]  # fmt: skip

# A graded rate that moved less than this, relative to the previous take, is "same".
SAME_RATE_BAND = 0.10


def _get(metrics: dict[str, Any], path: tuple[str, ...]) -> Any:
    value: Any = metrics
    for key in path:
        if value is None:
            return None
        value = value.get(key)
    return value


def _change(before: float, after: float, kind: str) -> str:
    if kind == "rate":
        if before == after or (before and round(abs(after - before) / before, 9) < SAME_RATE_BAND):
            return "same"
    elif before == after:
        return "same"
    return "better" if after < before else "worse"


def compare_metrics(previous: AnalysisDoc, current: AnalysisDoc) -> list[MetricChange]:
    """The fixed metric list of a retry's comparison, previous take first. Lower is better for
    every graded metric; the others are shown for information. Filler rates judged differently
    (rules on one take, coaching on the other) are not comparable, so they are information too."""
    resolutions = {_get(doc["metrics"], ("fillers", "resolution")) for doc in (previous, current)}
    changes = []
    for metric, label, unit, path, graded, kind in _COMPARED:
        before, after = _get(previous["metrics"], path), _get(current["metrics"], path)
        comparable = metric != "fillers_per_100_words" or len(resolutions) == 1
        if not graded or not comparable or before is None or after is None:
            change = "info"
        else:
            change = _change(before, after, kind)
        changes.append(
            {
                "metric": metric,
                "label": label,
                "unit": unit,
                "before": before,
                "after": after,
                "change": change,
            }
        )
    return changes
