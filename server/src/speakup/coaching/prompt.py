"""The coaching system prompt and the user content Claude sees for one take.

The prompt and rubric are versioned files in `resources/`. Each starts with a
`<!-- version: ... -->` line; the version goes into every report, and the line itself
is not sent. Change the version whenever the text changes in a way that can change
results, so reports stay comparable.

A Mandarin (`zh`) take adds `coach-zh.md` after the rubric: the instructions and rubric stay
one text for both languages, and the addition says where Mandarin differs (Chinese output,
verbatim Chinese quotes, per-character units, Mandarin fillers).
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from functools import cache
from pathlib import Path
from typing import Any

from speakup.text import join_words

RESOURCES = Path(__file__).parent / "resources"

_VERSION_LINE = re.compile(r"\A<!-- version: (\S+) -->\n")


@dataclass(frozen=True)
class VersionedText:
    version: str
    text: str


@cache
def load_resource(name: str) -> VersionedText:
    raw = (RESOURCES / name).read_text(encoding="utf-8")
    match = _VERSION_LINE.match(raw)
    if not match:
        raise ValueError(f"{name} must start with a '<!-- version: ... -->' line")
    return VersionedText(version=match.group(1), text=raw[match.end() :].strip() + "\n")


def coach_prompt() -> VersionedText:
    return load_resource("coach-prompt.md")


def rubric() -> VersionedText:
    return load_resource("rubric.md")


def questions_prompt() -> VersionedText:
    return load_resource("questions-prompt.md")


def language_addition(language: str) -> VersionedText | None:
    """The language-specific part of the system prompt, or None for English."""
    return load_resource("coach-zh.md") if language == "zh" else None


def prompt_version(language: str = "en") -> str:
    """The prompt version a report records: the coach prompt's, plus the addition's for zh."""
    addition = language_addition(language)
    version = coach_prompt().version
    return f"{version}+{addition.version}" if addition else version


def system_prompt(language: str = "en") -> str:
    """The coaching system prompt: instructions, then the rubric, then any language addition."""
    text = coach_prompt().text + "\n" + rubric().text
    addition = language_addition(language)
    return text + "\n" + addition.text if addition else text


# ---------------------------------------------------------------------------
# User content

_WORDS_PER_LINE = 20


def _num(value: Any, digits: int = 2) -> str:
    if value is None:
        return "n/a"
    if isinstance(value, float):
        text = f"{value:.{digits}f}"
        return text.rstrip("0").rstrip(".") if "." in text else text
    return str(value)


def indexed_transcript(words: list[dict[str, Any]]) -> str:
    """Words as `[i]text`, wrapped every few words so long takes stay readable."""
    tokens = [f"[{w['i']}]{w['text']}" for w in words]
    lines = [
        " ".join(tokens[k : k + _WORDS_PER_LINE]) for k in range(0, len(tokens), _WORDS_PER_LINE)
    ]
    return "\n".join(lines)


def plain_transcript(words: list[dict[str, Any]], language: str = "en") -> str:
    return join_words([w["text"] for w in words], language)


def _indexed(words: list[dict[str, Any]], start: int, end: int) -> str:
    return " ".join(f"[{w['i']}]{w['text']}" for w in words[start:end])


def rule_events(analysis: dict[str, Any]) -> list[dict[str, Any]]:
    """Events found by rules. Coaching events of a re-coached take are left out."""
    return [e for e in analysis["events"] if e.get("source", "rules") == "rules"]


def lexical_filler_ids(analysis: dict[str, Any]) -> list[str]:
    return [e["id"] for e in rule_events(analysis) if e["type"] == "lexical_filler"]


def _event_line(event: dict[str, Any], words: list[dict[str, Any]]) -> str | None:
    kind = event["type"]
    ws, we = event["word_start"], event["word_end"]
    words_part = _indexed(words, ws, we)
    reason = f" ({event['reason']})" if event.get("reason") else ""
    if kind == "boundary_pause":
        return None
    if kind == "block":
        seconds = event["end"] - event["start"]
        # A block spans the whole hesitation: its silences plus any filled pause inside it.
        return f"{event['id']} block{reason}: {_num(seconds)} s hesitation before word {ws}"
    if kind == "lexical_filler":
        guess = "filler" if event.get("is_filler") else "not a filler"
        return f"{event['id']} lexical_filler: {words_part}; rules' guess: {guess}"
    if kind in ("restart", "repetition") and event.get("repair_word") is not None:
        repair = event["repair_word"]
        return f"{event['id']} {kind}{reason}: {words_part}; repair starts at word {repair}"
    return f"{event['id']} {kind}{reason}: {words_part}"


def events_block(analysis: dict[str, Any]) -> str:
    words = analysis["words"]
    lines = [line for e in rule_events(analysis) if (line := _event_line(e, words))]
    return "\n".join(lines) if lines else "None."


def metrics_block(metrics: dict[str, Any], language: str = "en") -> str:
    if language == "zh":
        return _metrics_block_zh(metrics)
    f = metrics["fillers"]
    b = metrics["blocks"]
    bp = metrics["boundary_pauses"]
    pace = metrics["pace"]
    quarters = ", ".join(_num(q, 0) for q in pace.get("by_quarter_wpm") or [])
    lines = [
        f"Recording {_num(metrics['duration_s'], 1)} s; first word after "
        f"{_num(metrics['speech_start_s'], 1)} s; speaking {_num(metrics['speaking_s'], 1)} s; "
        f"{metrics['word_count']} words.",
        f"Fillers: {f['filled_pauses']} filled pauses (um, uh), {f['lexical']} of "
        f"{f['lexical_candidates']} lexical candidates judged fillers by rules; "
        f"{_num(f['per_100_words'])} per 100 words (ordinary speech: about 2 to 6).",
        f"Blocks: {b['count']} ({_num(b['per_minute'])} per minute), longest "
        f"{_num(b['longest_s'])} s, total {_num(b['total_s'])} s.",
        f"Restarts: {metrics['restarts']}. Repetitions: {metrics['repetitions']}.",
        f"Boundary pauses (normal): {bp['count']}, median {_num(bp['median_s'])} s.",
        f"Pace (information only, not graded): {_num(pace['wpm_voiced'], 0)} words per minute"
        + (f"; by quarter {quarters}." if quarters else "."),
    ]
    return "\n".join(lines)


def _metrics_block_zh(metrics: dict[str, Any]) -> str:
    """The metrics of a Mandarin take, whose word counts and rates are per character."""
    f = metrics["fillers"]
    b = metrics["blocks"]
    bp = metrics["boundary_pauses"]
    pace = metrics["pace"]
    quarters = ", ".join(_num(q, 0) for q in pace.get("by_quarter_wpm") or [])
    lines = [
        f"Recording {_num(metrics['duration_s'], 1)} s; first word after "
        f"{_num(metrics['speech_start_s'], 1)} s; speaking {_num(metrics['speaking_s'], 1)} s; "
        f"{metrics['word_count']} characters.",
        f"Fillers: {f['filled_pauses']} filled pauses (嗯, 呃), {f['lexical']} of "
        f"{f['lexical_candidates']} lexical candidates judged fillers by rules; "
        f"{_num(f['per_100_words'])} per 100 characters.",
        f"Blocks: {b['count']} ({_num(b['per_minute'])} per minute), longest "
        f"{_num(b['longest_s'])} s, total {_num(b['total_s'])} s.",
        f"Restarts: {metrics['restarts']}. Repetitions: {metrics['repetitions']}.",
        f"Boundary pauses (normal): {bp['count']}, median {_num(bp['median_s'])} s.",
        f"Pace (information only, not graded): {_num(pace['wpm_voiced'], 0)} characters per "
        "minute" + (f"; by quarter {quarters}." if quarters else "."),
    ]
    return "\n".join(lines)


def nervousness_block(analysis: dict[str, Any]) -> str:
    signs = analysis.get("nervousness_signs") or []
    return "\n".join(s["detail"] for s in signs) if signs else "None."


def _prompt_block(prompt: dict[str, Any], attempt: int, language: str) -> str:
    lines = [f"Kind: {prompt['kind']}"]
    if language == "zh":
        lines.append("Language: Mandarin Chinese; write your coaching in Simplified Chinese")
    if prompt.get("category"):
        lines.append(f"Category: {prompt['category']}")
    label = "Question" if prompt["kind"] == "impromptu" else "Title"
    lines.append(f"{label}: {prompt['text']}")
    if prompt.get("notes"):
        lines.append("His notes before recording:\n" + prompt["notes"].strip())
    lines.append(f"Suggested length: {prompt['target_seconds']} seconds")
    lines.append(f"Attempt: {attempt}")
    return "\n".join(lines)


def _previous_block(previous: dict[str, Any], language: str) -> str:
    analysis = previous["analysis"]
    parts = [
        f'<previous_take attempt="{previous["attempt"]}">',
        "<transcript>",
        plain_transcript(analysis["words"], language),
        "</transcript>",
        "<metrics>",
        metrics_block(analysis["metrics"], language),
        "</metrics>",
    ]
    coaching = previous.get("coaching")
    if coaching:
        parts.append("<previous_focus>")
        for index, item in enumerate(coaching["focus"]):
            parts.append(
                f"Focus {index} ({item['dimension']}): {item['title']}. "
                f"Problem: {item['problem']} Instruction: {item['instruction']}"
            )
        parts.append("</previous_focus>")
        levels = ", ".join(
            f"{name} {value['level']}" for name, value in coaching["dimensions"].items()
        )
        parts.append(f"<previous_levels>{levels}</previous_levels>")
    parts.append("</previous_take>")
    return "\n".join(parts)


def request_language(request: dict[str, Any]) -> str:
    """The take's language: the prompt's, else the analysis's, else English."""
    return request["prompt"].get("language") or request["analysis"].get("language") or "en"


def user_content(request: dict[str, Any]) -> str:
    """Everything Claude needs about one take, as tagged plain text."""
    analysis = request["analysis"]
    previous = request.get("previous")
    language = request_language(request)
    filler_ids = lexical_filler_ids(analysis)
    parts = [
        "<prompt>",
        _prompt_block(request["prompt"], request["attempt"], language),
        "</prompt>",
        "<transcript>",
        indexed_transcript(analysis["words"]),
        "</transcript>",
        "<rule_events>",
        events_block(analysis),
        "</rule_events>",
        "<metrics>",
        metrics_block(analysis["metrics"], language),
        "</metrics>",
        "<nervousness_signs>",
        nervousness_block(analysis),
        "</nervousness_signs>",
    ]
    if previous is not None:
        parts.append(_previous_block(previous, language))

    asks = ["Coach this take."]
    asks.append(
        "Rule on these lexical filler events: " + ", ".join(filler_ids) + "."
        if filler_ids
        else "There are no lexical filler events, so filler_rulings is empty."
    )
    if previous is not None and previous.get("coaching"):
        count = len(previous["coaching"]["focus"])
        asks.append(
            f"This is a retry: fill comparison with one outcome for each of the {count} "
            "previous focus items."
        )
    else:
        asks.append("There is no previous coaching to compare with, so comparison is null.")
    parts.append("\n".join(asks))
    return "\n".join(parts)


def reask_content(errors: list[str], previous_output: str) -> str:
    """Appended to the original request when the first output failed validation."""
    listed = "\n".join(f"- {e}" for e in errors)
    return (
        "<invalid_previous_output>\n"
        f"{previous_output.strip()}\n"
        "</invalid_previous_output>\n"
        "Your previous output for this take failed these checks:\n"
        f"{listed}\n"
        "Return the full coaching output again with these problems fixed. "
        "Keep everything that was already right."
    )
