"""Checks the schema cannot express, anchor repair, and anchor times.

Rules from docs/architecture.md#schema-rules:
- 1 or 2 focus items, 1 to 3 evidence anchors per focus item.
- On a retry with previous coaching, one focus outcome per previous focus item.
- A filler ruling for every lexical filler event in the input, and no others.
- Every anchor covers at least one word, in range, and its quote matches those words after
  normalization. A wrong range is repaired by searching for the quote.
"""

from __future__ import annotations

import re
from typing import Any

from pydantic import ValidationError

from .models import DIMENSIONS, Anchor, CoachingOutput

_TOKEN = re.compile(r"[a-z0-9]+(?:'[a-z0-9]+)*")
_MARKDOWN = re.compile(r"\*\*|__|`|^\s*(?:#{1,6}\s|[-*•]\s)", re.MULTILINE)


def tokens(text: str) -> list[str]:
    """Lowercase word tokens, ignoring punctuation and cut-off hyphens."""
    text = text.lower().replace("’", "'").replace("‘", "'")
    return _TOKEN.findall(text)


class Transcript:
    """The take's words, tokenized once for quote matching."""

    def __init__(self, words: list[dict[str, Any]]) -> None:
        self.words = words
        self.word_tokens = [tokens(w["text"]) for w in words]

    def __len__(self) -> int:
        return len(self.words)

    def range_tokens(self, start: int, end: int) -> list[str]:
        return [t for toks in self.word_tokens[start:end] for t in toks]

    def find(self, quote_tokens: list[str]) -> list[tuple[int, int]]:
        """Every word range whose tokens equal `quote_tokens`, trimmed to non-empty edges."""
        found: list[tuple[int, int]] = []
        n = len(quote_tokens)
        for start in range(len(self.words)):
            if not self.word_tokens[start] or self.word_tokens[start][0] != quote_tokens[0]:
                continue
            collected: list[str] = []
            end = start
            while end < len(self.words) and len(collected) < n:
                collected.extend(self.word_tokens[end])
                end += 1
            if collected == quote_tokens:
                found.append((start, end))
        return found

    def times(self, start: int, end: int) -> tuple[float, float]:
        return self.words[start]["start"], self.words[end - 1]["end"]


def check_anchor(anchor: Anchor, transcript: Transcript, where: str) -> str | None:
    """Validate an anchor in place, repairing its range from the quote. Returns an error."""
    quote_tokens = tokens(anchor.quote)
    if not quote_tokens:
        return f"{where}: the quote has no words."
    in_range = 0 <= anchor.word_start < anchor.word_end <= len(transcript)
    if in_range and transcript.range_tokens(anchor.word_start, anchor.word_end) == quote_tokens:
        return None
    matches = transcript.find(quote_tokens)
    if not matches:
        return (
            f'{where}: the quote "{anchor.quote}" does not appear in the transcript; '
            "copy the words exactly and contiguously."
        )
    start, end = min(matches, key=lambda m: abs(m[0] - anchor.word_start))
    anchor.word_start, anchor.word_end = start, end
    return None


def _check_range(start: int, end: int, size: int, where: str) -> str | None:
    if not 0 <= start < end <= size:
        return (
            f"{where}: word range {start} to {end} must cover at least one word within 0 to {size}."
        )
    return None


def _texts(output: CoachingOutput) -> list[tuple[str, str]]:
    items = [("verdict", output.verdict), ("strength.point", output.strength.point)]
    for i, f in enumerate(output.focus):
        items += [
            (f"focus[{i}].title", f.title),
            (f"focus[{i}].problem", f.problem),
            (f"focus[{i}].instruction", f.instruction),
        ]
    for name in DIMENSIONS:
        items.append((f"dimensions.{name}.evidence", getattr(output.dimensions, name).evidence))
    items += [
        ("outline.main_point", output.outline.main_point),
        ("reference_version.text", output.reference_version.text),
        ("reference_version.structure", output.reference_version.structure),
    ]
    items += [(f"annotations[{i}].note", a.note) for i, a in enumerate(output.annotations)]
    if output.comparison is not None:
        items.append(("comparison.summary", output.comparison.summary))
        items += [
            (f"comparison.focus_outcomes[{i}].evidence", o.evidence)
            for i, o in enumerate(output.comparison.focus_outcomes)
        ]
    return items


def validate_output(
    raw: str,
    *,
    words: list[dict[str, Any]],
    lexical_filler_ids: list[str],
    previous_focus_count: int | None,
) -> tuple[CoachingOutput | None, list[str]]:
    """Parse and check one coaching output. Returns the repaired output, or the errors.

    `previous_focus_count` is the number of focus items in the previous take's coaching,
    or None when there is no previous coaching (then `comparison` is forced to null).
    """
    try:
        output = CoachingOutput.model_validate_json(raw)
    except ValidationError as exc:
        errors = [
            f"{'.'.join(str(p) for p in e['loc']) or 'output'}: {e['msg']}" for e in exc.errors()
        ]
        return None, errors[:20]

    transcript = Transcript(words)
    errors: list[str] = []

    def anchor(a: Anchor, where: str) -> None:
        if (error := check_anchor(a, transcript, where)) is not None:
            errors.append(error)

    for where, text in _texts(output):
        if not text.strip():
            errors.append(f"{where}: must not be empty.")
        elif _MARKDOWN.search(text):
            errors.append(f"{where}: write plain text, without Markdown or bullet characters.")

    anchor(output.strength.anchor, "strength.anchor")

    if not 1 <= len(output.focus) <= 2:
        errors.append(f"focus: give 1 or 2 items, not {len(output.focus)}.")
    for i, item in enumerate(output.focus):
        if not 1 <= len(item.evidence) <= 3:
            errors.append(f"focus[{i}].evidence: give 1 to 3 anchors, not {len(item.evidence)}.")
        for j, a in enumerate(item.evidence):
            anchor(a, f"focus[{i}].evidence[{j}]")

    if not output.outline.points:
        errors.append("outline.points: list at least one point.")
    for i, p in enumerate(output.outline.points):
        if (
            e := _check_range(p.word_start, p.word_end, len(words), f"outline.points[{i}]")
        ) is not None:
            errors.append(e)

    for i, a in enumerate(output.annotations):
        if (
            e := _check_range(a.word_start, a.word_end, len(words), f"annotations[{i}]")
        ) is not None:
            errors.append(e)

    ruled = [r.event_id for r in output.filler_rulings]
    expected = set(lexical_filler_ids)
    missing = [i for i in lexical_filler_ids if i not in ruled]
    unknown = sorted(set(ruled) - expected)
    duplicated = sorted({i for i in ruled if ruled.count(i) > 1})
    if missing:
        errors.append(f"filler_rulings: missing rulings for {', '.join(missing)}.")
    if unknown:
        errors.append(
            f"filler_rulings: {', '.join(unknown)} are not lexical filler events; "
            "rule only on the listed ones."
        )
    if duplicated:
        errors.append(f"filler_rulings: rule once on each of {', '.join(duplicated)}.")

    if previous_focus_count is None:
        output.comparison = None
    elif output.comparison is None:
        errors.append("comparison: this is a retry with previous coaching; fill comparison.")
    else:
        indexes = [o.previous_focus_index for o in output.comparison.focus_outcomes]
        if sorted(indexes) != list(range(previous_focus_count)):
            errors.append(
                "comparison.focus_outcomes: give exactly one outcome for each previous focus "
                f"index 0 to {previous_focus_count - 1}; got {indexes}."
            )
        for i, o in enumerate(output.comparison.focus_outcomes):
            if o.anchor is not None:
                anchor(o.anchor, f"comparison.focus_outcomes[{i}].anchor")
        output.comparison.focus_outcomes.sort(key=lambda o: o.previous_focus_index)

    return (None, errors) if errors else (output, [])


def _timed(anchor: dict[str, Any] | None, transcript: Transcript) -> dict[str, Any] | None:
    if anchor is None:
        return None
    start, end = transcript.times(anchor["word_start"], anchor["word_end"])
    return {**anchor, "start": start, "end": end}


def add_anchor_times(output: dict[str, Any], words: list[dict[str, Any]]) -> dict[str, Any]:
    """Give every anchor `start` and `end` in seconds, from its words."""
    transcript = Transcript(words)
    output["strength"]["anchor"] = _timed(output["strength"]["anchor"], transcript)
    for item in output["focus"]:
        item["evidence"] = [_timed(a, transcript) for a in item["evidence"]]
    if output["comparison"] is not None:
        for outcome in output["comparison"]["focus_outcomes"]:
            outcome["anchor"] = _timed(outcome["anchor"], transcript)
    return output
