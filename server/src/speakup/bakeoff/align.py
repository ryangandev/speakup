"""Word alignment between a gold transcript and an engine's transcript."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Literal

from speakup.text import Token

Op = Literal["match", "sub", "del", "ins"]


@dataclass(frozen=True)
class Pair:
    """One alignment step. `del` is a gold token the engine missed; `ins` is an engine token
    with no gold counterpart."""

    op: Op
    gold: Token | None
    hyp: Token | None


def same_word(gold: Token, hyp: Token) -> bool:
    if gold.text == hyp.text:
        return True
    if not (gold.cutoff or hyp.cutoff):
        return False
    # Engines spell a fragment differently ("th-" vs "the-"), or write a very short fragment as
    # the short word it sounds like ("th-" vs "the"). Both still show the fragment was heard.
    shorter, longer = sorted((gold.text, hyp.text), key=len)
    return longer.startswith(shorter) and ((gold.cutoff and hyp.cutoff) or len(longer) <= 3)


def substitution_cost(gold: Token, hyp: Token) -> float:
    """0 for the same word. Two different filled pauses cost half, so "uh" heard as "um" aligns
    with it instead of with a neighbouring word when the costs would otherwise tie."""
    if same_word(gold, hyp):
        return 0.0
    if gold.is_filled_pause and hyp.is_filled_pause:
        return 0.5
    return 1.0


def align(gold: list[Token], hyp: list[Token]) -> list[Pair]:
    """Minimum edit distance alignment; insertions and deletions cost 1."""
    n, m = len(gold), len(hyp)
    cost = [[0.0] * (m + 1) for _ in range(n + 1)]
    for i in range(1, n + 1):
        cost[i][0] = i
    for j in range(1, m + 1):
        cost[0][j] = j
    for i in range(1, n + 1):
        row, prev = cost[i], cost[i - 1]
        g = gold[i - 1]
        for j in range(1, m + 1):
            diagonal = prev[j - 1] + substitution_cost(g, hyp[j - 1])
            row[j] = min(diagonal, prev[j] + 1, row[j - 1] + 1)

    pairs: list[Pair] = []
    i, j = n, m
    while i > 0 or j > 0:
        if i > 0 and j > 0:
            sub = substitution_cost(gold[i - 1], hyp[j - 1])
            if cost[i][j] == cost[i - 1][j - 1] + sub:
                pairs.append(Pair("match" if sub == 0 else "sub", gold[i - 1], hyp[j - 1]))
                i, j = i - 1, j - 1
                continue
        if i > 0 and cost[i][j] == cost[i - 1][j] + 1:
            pairs.append(Pair("del", gold[i - 1], None))
            i -= 1
        else:
            pairs.append(Pair("ins", None, hyp[j - 1]))
            j -= 1
    pairs.reverse()
    return pairs
