"""Build hand-made takes for the analysis tests."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from speakup.analysis import build_analysis
from speakup.analysis.acoustics import Acoustics
from speakup.stt import Transcript, Word

FIXTURES = Path(__file__).parent / "fixtures"


def load_fixture(name: str) -> dict[str, Any]:
    return json.loads((FIXTURES / name).read_text())


def words_from(script: str, *, word_s: float = 0.2, gap_s: float = 0.05) -> list[Word]:
    """Timed words from a script: each word lasts `word_s`, words are `gap_s` apart, and a
    token like `|0.6|` puts that many seconds of silence before the next word."""
    words, cursor, gap = [], 0.5, 0.0
    for token in script.split():
        if token.startswith("|") and token.endswith("|"):
            gap = float(token.strip("|"))
            continue
        start = round(cursor + (gap if words else 0.0), 3)
        words.append(Word(token, start, round(start + word_s, 3), 0.95))
        cursor, gap = start + word_s, gap_s
    return words


def transcript_from(words: list[Word]) -> Transcript:
    return Transcript("crisper-large", " ".join(w.text for w in words), words, 0.0)


def analyze_script(
    script: str, *, speech: list[tuple[float, float]] | None = None, **timing: float
) -> dict[str, Any]:
    """Analyze a script without audio. With no `speech`, the voice track falls back to the word
    times, so pauses are exactly the scripted gaps."""
    words = words_from(script, **timing)
    acoustics = Acoustics(duration_s=words[-1].end + 0.5, speech=speech or [])
    return build_analysis(take_id="t", transcript=transcript_from(words), acoustics=acoustics)


def events_of(doc: dict[str, Any], type_: str) -> list[dict[str, Any]]:
    return [e for e in doc["events"] if e["type"] == type_]


def summary(doc: dict[str, Any], type_: str) -> list[tuple]:
    """(first word text, word_start, word_end, reason) for each event of a type."""
    texts = [w["text"] for w in doc["words"]]
    return [
        (texts[e["word_start"]], e["word_start"], e["word_end"], e["reason"])
        for e in events_of(doc, type_)
    ]
