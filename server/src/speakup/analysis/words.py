"""The `words` list of the analysis document, and small helpers for reading it.

Words stay in engine order and keep the engine's text, so the transcript the app renders and the
indexes coaching quotes are the same list. See docs/architecture.md#words.
"""

from __future__ import annotations

import math
from typing import Any

from speakup.stt import Word
from speakup.text import tokens_from_words

WordDoc = dict[str, Any]

SENTENCE_END = (".", "?", "!")
CLAUSE_END = (",", ";", ":")
# Closing quotes and brackets that may follow a word's final punctuation.
_TRAILING = "\"'”’)]}"


def _confidence(value: float | None) -> float | None:
    """The engine's confidence, or None when it gave none or a non-finite number (NaN, inf),
    which JSON cannot carry."""
    if value is None or not math.isfinite(value):
        return None
    return float(value)


def word_docs(words: list[Word]) -> list[WordDoc]:
    docs = []
    for i, word in enumerate(words):
        tokens = tokens_from_words([word])
        norm = " ".join(t.text for t in tokens)
        if not tokens:
            kind = "non_speech"
        elif len(tokens) == 1 and tokens[0].is_filled_pause:
            kind = "filled_pause"
        else:
            kind = "word"
        docs.append(
            {
                "i": i,
                "text": word.text,
                "norm": norm,
                "start": float(word.start),
                "end": float(word.end),
                "confidence": _confidence(word.confidence),
                "kind": kind,
                "cutoff": bool(tokens) and tokens[-1].cutoff,
            }
        )
    return docs


def final_punctuation(word: WordDoc) -> str:
    """The punctuation mark that ends the word's text, or "" when there is none.

    An ellipsis is a trail-off, not the end of a sentence, so it returns "...".
    """
    text = word["text"].rstrip().rstrip(_TRAILING)
    if text.endswith(("...", "\N{HORIZONTAL ELLIPSIS}")):
        return "..."
    return text[-1] if text and text[-1] in SENTENCE_END + CLAUSE_END else ""


def ends_sentence(word: WordDoc) -> bool:
    return final_punctuation(word) in SENTENCE_END


def ends_clause(word: WordDoc) -> bool:
    return final_punctuation(word) in CLAUSE_END


def content_indexes(words: list[WordDoc]) -> list[int]:
    """Indexes of words of kind `word`: what remains once filled pauses and sounds are skipped."""
    return [w["i"] for w in words if w["kind"] == "word"]


def spoken(words: list[WordDoc]) -> list[WordDoc]:
    """Words and filled pauses: everything the speaker voiced, without sounds like laughter."""
    return [w for w in words if w["kind"] != "non_speech"]
