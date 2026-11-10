"""Turn transcripts from different engines and hand-written gold text into comparable tokens.

Engines write the same speech differently: "[UM]", "Um,", "umm" for a filler; a hyphen or a long
dash after a cut-off word; "(laughter)" for a sound. Normalizing them lets alignment compare
what was said, not how each engine writes it.

Mandarin (`zh`) transcripts have no spaces: an engine writes one token per character or word,
with punctuation attached or absent. Their Chinese characters are kept as written (punctuation
stripped, nothing else changed); Latin-script words inside them follow the English rules.
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


# -- Mandarin -------------------------------------------------------------------------------

LANGUAGES = ("en", "zh")

# Han characters: the CJK Unified Ideographs blocks and their extensions.
_CJK_CLASS = "\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\U00020000-\U0003134f"
_CJK_RUN = re.compile(f"[{_CJK_CLASS}]+")
_CJK_ONLY = re.compile(f"^[{_CJK_CLASS}]+$")
# Full-width and CJK punctuation, removed before Latin-script pieces are normalized.
_ZH_PUNCTUATION = "，。？！、：；“”‘’（）《》〈〉「」『』【】…～·．\u3000"
_ZH_BRACKETED = re.compile(r"^[（【［](.*)[）】］]$")

# Mandarin filled pauses that are never part of a word: always a filled pause, alone or doubled.
ZH_FILLED_PAUSES = {"嗯", "呃"}
# Hesitation sounds that are also characters of ordinary words (额 in 金额 or 额外): a filled
# pause only when set off on both sides. See speakup.analysis.zh.
ZH_FILLED_PAUSES_STANDALONE = {"额", "唔"}
# Interjections that are also sentence-final particles (好啊, 是哦): a filled pause only when not
# attached to the word before. See speakup.analysis.zh.
ZH_INTERJECTIONS = {"啊", "哦", "噢"}


def is_cjk(text: str) -> bool:
    """Whether `text` is one or more Han characters and nothing else."""
    return bool(_CJK_ONLY.match(text))


def _zh_latin(segment: str) -> list[tuple[str, bool]]:
    for mark in _ZH_PUNCTUATION:
        segment = segment.replace(mark, " ")
    pairs: list[tuple[str, bool]] = []
    for piece in segment.split():
        pairs.extend(_normalize_piece(piece))
    return pairs


def _normalize_zh(raw: str) -> list[tuple[str, bool]]:
    """Normalize one Mandarin engine token: runs of Han characters stay whole and unchanged,
    punctuation goes, and Latin-script pieces follow the English rules. A token that ends in a
    dash was broken off."""
    text = raw.strip()
    bracketed = _ZH_BRACKETED.match(text) or _BRACKETED.match(text)
    if bracketed:
        inner = bracketed.group(1).strip()
        if inner.lower() in FILLED_PAUSES:
            return [(FILLED_PAUSES[inner.lower()], False)]
        return [(inner, False)] if inner and set(inner) <= ZH_FILLED_PAUSES else []
    pairs: list[tuple[str, bool]] = []
    position = 0
    for run in _CJK_RUN.finditer(text):
        pairs.extend(_zh_latin(text[position : run.start()]))
        pairs.append((run.group(), False))
        position = run.end()
    pairs.extend(_zh_latin(text[position:]))
    tail = text.rstrip(_EDGE_PUNCTUATION.replace("-", "") + _ZH_PUNCTUATION)
    if pairs and tail.endswith(CUTOFF_DASHES):
        pairs[-1] = (pairs[-1][0], True)
    return pairs


def zh_units(norm: str) -> list[str]:
    """The spoken units of a Mandarin word's `norm`: each Han character is one, each
    Latin-script word is one. Rates and counts for `zh` are per unit."""
    units: list[str] = []
    for piece in norm.split():
        units.extend(piece if is_cjk(piece) else [piece])
    return units


def join_words(texts: list[str], language: str = "en") -> str:
    """Words as running text: separated by spaces in English; in Mandarin, a space only between
    two Latin-script words, so Chinese reads without the gaps an engine's tokens would leave."""
    if language != "zh":
        return " ".join(texts)
    out = ""
    for text in texts:
        latin_pair = out[-1:].isascii() and out[-1:].isalnum() and text[:1].isascii()
        if latin_pair and text[:1].isalnum():
            out += " "
        out += text
    return out


# -- Tokens -----------------------------------------------------------------------------------


def tokens_from_text(text: str) -> list[Token]:
    """Tokens of untimed text, such as a gold transcript. Lines starting with # are comments."""
    lines = [line for line in text.splitlines() if not line.lstrip().startswith("#")]
    tokens: list[Token] = []
    for piece in " ".join(lines).split():
        tokens.extend(Token(t, c) for t, c in _normalize_piece(piece))
    return tokens


def tokens_from_words(words: list[Word], language: str = "en") -> list[Token]:
    """Tokens of timed engine output. A word that splits into several tokens shares its times."""
    tokens: list[Token] = []
    for word in words:
        if language == "zh":
            tokens.extend(Token(t, c, word.start, word.end) for t, c in _normalize_zh(word.text))
            continue
        for piece in word.text.split():
            tokens.extend(Token(t, c, word.start, word.end) for t, c in _normalize_piece(piece))
    return tokens
