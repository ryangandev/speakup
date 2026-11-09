import pytest

from speakup.bakeoff.metrics import (
    Gap,
    repetitions,
    score_against_gold,
    score_pauses,
    word_gaps,
)
from speakup.text import Token, tokens_from_text


def test_repetitions_skip_fillers_and_cover_phrases():
    tokens = tokens_from_text("we um we need to the to the server")
    # "we" repeated across a filler, then "to the" repeated as a phrase.
    assert repetitions(tokens) == {2: 0, 6: 4, 7: 5}


def test_gold_score_counts_what_survived():
    gold = tokens_from_text("um so we we need to uh mi- migrate")
    hyp = tokens_from_text("so we need to um migrate")
    score = score_against_gold(gold, hyp)
    assert score.gold_words == 9
    assert score.filled_gold == 2
    assert score.filled_found == 1  # "uh" heard as "um" still flags the hesitation
    assert score.filled_precision == 1.0
    # The engine wrote "we" once, so the repetition was lost even though one "we" matches.
    assert score.repeats_gold == 1 and score.repeats_kept == 0
    assert score.cutoffs_gold == 1 and score.cutoffs_kept == 0
    # Missed "um", the lost "we", "uh" written as "um", and the missed fragment.
    assert score.wer == pytest.approx(4 / 9)


def test_word_gaps_use_timed_tokens():
    tokens = [
        Token("a", start=0.0, end=0.5),
        Token("b", start=0.6, end=1.0),
        Token("c", start=1.5, end=2.0),
    ]
    assert word_gaps(tokens) == [Gap(1.0, 1.5)]


def test_pause_matching_and_edge_error():
    reference = [Gap(1.0, 1.5), Gap(3.0, 3.4)]
    engine = [Gap(1.04, 1.46), Gap(5.0, 5.5)]
    score = score_pauses(reference, engine)
    assert (score.matched, score.recall, score.precision) == (1, 0.5, 0.5)
    assert score.boundary_error_ms == pytest.approx(40)
