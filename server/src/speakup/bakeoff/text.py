"""Turn transcripts from different engines and hand-written gold text into comparable tokens.

Engines write the same speech differently: "[UM]", "Um,", "umm" for a filler; a hyphen or a long
dash after a cut-off word; "(laughter)" for a sound. Normalizing them lets alignment compare
what was said, not how each engine writes it.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

from speakup.stt import Word

# Filled pauses, mapped to one spelling each. Lexical fillers ("like", "so") are real words and
# need context to judge, so they are not normalized here.
FILLED_PAUSES = {
    "um": "um",
    "umm": "um",
    "ummm": "um",
    "uhm": "um",
    "erm": "um",
    "uh": "uh",
    "uhh": "uh",
    "uhhh": "uh",
    "er": "uh",
    "err": "uh",
    "ah": "uh",
    "ahh": "uh",
    "hmm": "hmm",
    "hm": "hmm",
    "hmmm": "hmm",
    "mm": "hmm",
    "mmm": "hmm",
}
CUTOFF_DASHES = ("-", "\N{EM DASH}", "\N{EN DASH}")
_BRACKETED = re.compile(r"^[\[(<{](.*)[\])>}]$")
_EDGE_PUNCTUATION = ".,!?;:\"'“”‘’…()[]{}<>*"


@dataclass(frozen=True)
class Token:
    """One normalized word. `cutoff` marks a word broken off mid-way, stored without its dash."""

    text: str
    cutoff: bool = False
    start: float | None = None
    end: float | None = None

    @property
    def is_filled_pause(self) -> bool:
        return self.text in FILLED_PAUSES.values()

    def __str__(self) -> str:
        return f"{self.text}-" if self.cutoff else self.text


def _normalize_piece(raw: str) -> list[tuple[str, bool]]:
    """Normalize one whitespace-separated piece into zero or more (text, cutoff) pairs."""
    piece = raw.strip()
    bracketed = _BRACKETED.match(piece)
    if bracketed:
        inner = bracketed.group(1).strip().lower()
        # "[um]" is a filler; "[laughter]" is a sound, not a word.
        return [(FILLED_PAUSES[inner], False)] if inner in FILLED_PAUSES else []

    piece = piece.lower().strip(_EDGE_PUNCTUATION)
    cutoff = piece.endswith(CUTOFF_DASHES)
    piece = piece.rstrip("".join(CUTOFF_DASHES)).strip(_EDGE_PUNCTUATION)
    if not piece:
        return []

    # "follow-up" and "follow up" should compare equal, so split internal hyphens.
    parts = [p.strip(_EDGE_PUNCTUATION) for p in re.split("[-\N{EM DASH}\N{EN DASH}]", piece)]
    parts = [p for p in parts if p]
    pairs = [(FILLED_PAUSES.get(p, p), False) for p in parts]
    if cutoff and pairs:
        pairs[-1] = (pairs[-1][0], True)
    return pairs


def tokens_from_text(text: str) -> list[Token]:
    """Tokens of untimed text, such as a gold transcript. Lines starting with # are comments."""
    lines = [line for line in text.splitlines() if not line.lstrip().startswith("#")]
    tokens: list[Token] = []
    for piece in " ".join(lines).split():
        tokens.extend(Token(t, c) for t, c in _normalize_piece(piece))
    return tokens


def tokens_from_words(words: list[Word]) -> list[Token]:
    """Tokens of timed engine output. A word that splits into several tokens shares its times."""
    tokens: list[Token] = []
    for word in words:
        for piece in word.text.split():
            tokens.extend(Token(t, c, word.start, word.end) for t, c in _normalize_piece(piece))
    return tokens
