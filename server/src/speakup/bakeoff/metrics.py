"""Bake-off measurements.

Against a gold transcript: verbatim word error rate, and whether filled pauses, repetitions and
cut-off words survive. Without a gold transcript: pause agreement with voice activity detection,
filler rate and speed.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from speakup.bakeoff.align import Pair, align
from speakup.bakeoff.text import Token

MIN_PAUSE_SECONDS = 0.25


@dataclass
class GoldScore:
    gold_words: int = 0
    errors: int = 0
    filled_gold: int = 0
    filled_found: int = 0
    filled_hyp: int = 0
    repeats_gold: int = 0
    repeats_kept: int = 0
    cutoffs_gold: int = 0
    cutoffs_kept: int = 0
    pairs: list[Pair] = field(default_factory=list)

    def add(self, other: GoldScore) -> None:
        for name in (
            "gold_words",
            "errors",
            "filled_gold",
            "filled_found",
            "filled_hyp",
            "repeats_gold",
            "repeats_kept",
            "cutoffs_gold",
            "cutoffs_kept",
        ):
            setattr(self, name, getattr(self, name) + getattr(other, name))

    @property
    def wer(self) -> float | None:
        return self.errors / self.gold_words if self.gold_words else None

    @property
    def filled_recall(self) -> float | None:
        return self.filled_found / self.filled_gold if self.filled_gold else None

    @property
    def filled_precision(self) -> float | None:
        return self.filled_found / self.filled_hyp if self.filled_hyp else None

    @property
    def repeats_recall(self) -> float | None:
        return self.repeats_kept / self.repeats_gold if self.repeats_gold else None

    @property
    def cutoffs_recall(self) -> float | None:
        return self.cutoffs_kept / self.cutoffs_gold if self.cutoffs_gold else None


def repetitions(tokens: list[Token]) -> dict[int, int]:
    """Map each token that repeats the words just before it to the token it repeats:
    in "we we" the second "we" maps to the first. Filled pauses between the copies are skipped,
    so "we, um, we" is still a repetition. Phrases of up to three words count: "to the, to the"."""
    content = [i for i, t in enumerate(tokens) if not t.is_filled_pause]
    words = [tokens[i].text for i in content]
    copies: dict[int, int] = {}
    k = 0
    while k < len(words):
        for n in (3, 2, 1):
            if k + 2 * n <= len(words) and words[k : k + n] == words[k + n : k + 2 * n]:
                for offset in range(n):
                    copies[content[k + n + offset]] = content[k + offset]
                k += n
                break
        else:
            k += 1
    return copies


def score_against_gold(gold: list[Token], hyp: list[Token]) -> GoldScore:
    pairs = align(gold, hyp)
    gold_index = {id(t): i for i, t in enumerate(gold)}
    repeats = repetitions(gold)
    score = GoldScore(gold_words=len(gold), pairs=pairs)
    score.errors = sum(p.op != "match" for p in pairs)
    score.repeats_gold = len(repeats)
    score.cutoffs_gold = sum(t.cutoff for t in gold)
    score.filled_gold = sum(t.is_filled_pause for t in gold)
    score.filled_hyp = sum(t.is_filled_pause for t in hyp)

    matched = {gold_index[id(p.gold)] for p in pairs if p.op == "match"}
    score.repeats_kept = sum(
        copy in matched and source in matched for copy, source in repeats.items()
    )

    for p in pairs:
        if p.gold is None or p.hyp is None:
            continue
        # A filled pause counts as found when the engine wrote any filled pause in its place;
        # "uh" heard as "um" still flags the hesitation.
        if p.gold.is_filled_pause and p.hyp.is_filled_pause:
            score.filled_found += 1
        if p.gold.cutoff:
            score.cutoffs_kept += 1
    return score


@dataclass(frozen=True)
class Gap:
    start: float
    end: float

    @property
    def length(self) -> float:
        return self.end - self.start


def word_gaps(tokens: list[Token], min_length: float = MIN_PAUSE_SECONDS) -> list[Gap]:
    timed = [t for t in tokens if t.start is not None and t.end is not None]
    gaps = []
    for a, b in zip(timed, timed[1:], strict=False):
        if b.start - a.end >= min_length:
            gaps.append(Gap(a.end, b.start))
    return gaps


@dataclass
class PauseScore:
    reference: int = 0
    engine: int = 0
    matched: int = 0
    boundary_error_sum: float = 0.0

    def add(self, other: PauseScore) -> None:
        self.reference += other.reference
        self.engine += other.engine
        self.matched += other.matched
        self.boundary_error_sum += other.boundary_error_sum

    @property
    def recall(self) -> float | None:
        return self.matched / self.reference if self.reference else None

    @property
    def precision(self) -> float | None:
        return self.matched / self.engine if self.engine else None

    @property
    def boundary_error_ms(self) -> float | None:
        return 1000 * self.boundary_error_sum / self.matched if self.matched else None


def score_pauses(reference: list[Gap], engine: list[Gap]) -> PauseScore:
    """Match each reference pause (from voice activity detection) to the engine pause that
    overlaps it most. Boundary error is the mean distance of the two edges."""
    score = PauseScore(reference=len(reference), engine=len(engine))
    used: set[int] = set()
    for ref in reference:
        best, best_overlap = None, 0.0
        for k, gap in enumerate(engine):
            overlap = min(ref.end, gap.end) - max(ref.start, gap.start)
            if k not in used and overlap > best_overlap:
                best, best_overlap = k, overlap
        if best is not None:
            used.add(best)
            score.matched += 1
            gap = engine[best]
            score.boundary_error_sum += (abs(gap.start - ref.start) + abs(gap.end - ref.end)) / 2
    return score
