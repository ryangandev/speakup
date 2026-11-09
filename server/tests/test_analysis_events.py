"""Each event rule on hand-built transcripts. Without audio, pauses are the scripted gaps."""

from __future__ import annotations

import json
import math

import numpy as np
import pytest
from analysis_helpers import analyze_script, events_of, summary, transcript_from, words_from

from speakup.analysis import build_analysis
from speakup.analysis.acoustics import Acoustics
from speakup.stt import Word

# --- Words ------------------------------------------------------------------------------------


def test_word_kinds_and_norms() -> None:
    doc = analyze_script("Umm, we [UH] need th- (laughter) the follow-up hmm today.")
    kinds = [(w["text"], w["norm"], w["kind"], w["cutoff"]) for w in doc["words"]]
    assert kinds == [
        ("Umm,", "um", "filled_pause", False),
        ("we", "we", "word", False),
        ("[UH]", "uh", "filled_pause", False),
        ("need", "need", "word", False),
        ("th-", "th", "word", True),
        ("(laughter)", "", "non_speech", False),
        ("the", "the", "word", False),
        ("follow-up", "follow up", "word", False),
        ("hmm", "hmm", "filled_pause", False),
        ("today.", "today", "word", False),
    ]
    assert [w["i"] for w in doc["words"]] == list(range(10))
    assert doc["metrics"]["word_count"] == 6


# --- Filled pauses -----------------------------------------------------------------------------


def test_filled_pauses_are_events() -> None:
    doc = analyze_script("Um, we need uh the hmm database today.")
    assert summary(doc, "filled_pause") == [
        ("Um,", 0, 1, None),
        ("uh", 3, 4, None),
        ("hmm", 5, 6, None),
    ]
    assert doc["metrics"]["fillers"]["filled_pauses"] == 3


# --- Lexical fillers ---------------------------------------------------------------------------


def _lexical(script: str) -> list[tuple[str, bool]]:
    doc = analyze_script(script)
    texts = [w["text"] for w in doc["words"]]
    return [
        (" ".join(texts[e["word_start"] : e["word_end"]]), e["is_filler"])
        for e in events_of(doc, "lexical_filler")
    ]


def test_like_set_off_by_commas_and_a_silence_is_a_filler() -> None:
    assert _lexical("we chose it because, like, |0.6| the queries need joins") == [("like,", True)]


def test_like_as_a_verb_is_not_a_candidate() -> None:
    assert _lexical("I like Postgres and we would like more joins") == []


def test_sentence_initial_so_needs_a_silence_after_it() -> None:
    assert _lexical("So |0.5| we picked Postgres for billing") == [("So", True)]
    assert _lexical("So um we picked Postgres for billing") == [("So", False)]
    assert _lexical("So, we picked Postgres for billing") == [("So,", False)]


def test_so_in_fixed_phrases_is_not_a_candidate() -> None:
    assert _lexical("we did it so that the reports and so on stay fast I think so") == []


def test_hedges_stay_candidates_judged_not_fillers_by_rules() -> None:
    assert _lexical("it is kind of slow and actually fine") == [
        ("kind of", False),
        ("actually", False),
    ]


def test_noun_uses_of_kind_of_are_not_candidates() -> None:
    assert _lexical("what kind of database is a sort of cache") == []


def test_you_know_between_commas_mid_sentence_is_a_filler() -> None:
    assert _lexical("we need, you know, more joins for reports") == [("you know,", True)]
    assert _lexical("do you know the answer to that") == []


def test_right_as_adjective_is_not_a_candidate() -> None:
    assert _lexical("that is the right database for us right now") == []


# --- Repetitions -------------------------------------------------------------------------------


def test_word_repetition() -> None:
    doc = analyze_script("then the the team picked it")
    assert summary(doc, "repetition") == [("the", 1, 3, "word")]
    assert events_of(doc, "repetition")[0]["repair_word"] == 2


def test_phrase_repetition() -> None:
    doc = analyze_script("I think I think we should migrate")
    assert summary(doc, "repetition") == [("I", 0, 4, "phrase")]
    assert events_of(doc, "repetition")[0]["repair_word"] == 2


def test_repetition_across_a_filler_and_a_pause() -> None:
    doc = analyze_script("so we um |0.4| we need the database")
    [rep] = events_of(doc, "repetition")
    assert (rep["word_start"], rep["word_end"], rep["repair_word"]) == (1, 4, 3)
    assert summary(doc, "filled_pause") == [("um", 2, 3, None)]


def test_three_copies_are_one_repetition() -> None:
    doc = analyze_script("then the the the team picked it")
    assert summary(doc, "repetition") == [("the", 1, 4, "word")]
    assert doc["metrics"]["repetitions"] == 1


def test_deliberate_doubles_need_a_hesitation() -> None:
    assert events_of(analyze_script("I think that that is the plan"), "repetition") == []
    assert events_of(analyze_script("we had had enough of it"), "repetition") == []
    doc = analyze_script("I think that, um, that is the plan")
    assert summary(doc, "repetition") == [("that,", 2, 5, "word")]


def test_no_repetition_across_a_sentence_end() -> None:
    assert events_of(analyze_script("No. No, that is wrong here"), "repetition") == []


# --- Restarts ----------------------------------------------------------------------------------


def test_cutoff_restart_reaches_back_to_the_repeated_start() -> None:
    doc = analyze_script("So um we nee- we picked Postgres")
    [restart] = events_of(doc, "restart")
    assert (restart["reason"], restart["word_start"], restart["word_end"]) == ("cutoff", 2, 4)
    assert restart["repair_word"] == 4
    assert restart["start"] == doc["words"][2]["start"]
    assert restart["end"] == doc["words"][3]["end"]
    assert events_of(doc, "repetition") == []


def test_cutoff_restart_of_a_single_word() -> None:
    doc = analyze_script("we need th- the database now")
    [restart] = events_of(doc, "restart")
    assert (restart["word_start"], restart["word_end"], restart["repair_word"]) == (2, 3, 3)


def test_consecutive_cutoffs_are_one_restart() -> None:
    doc = analyze_script("we need th- th- um the database")
    [restart] = events_of(doc, "restart")
    assert (restart["word_start"], restart["word_end"], restart["repair_word"]) == (2, 4, 5)


def test_cutoff_written_on_a_whole_word_is_a_restart_not_a_repetition() -> None:
    doc = analyze_script("we need the\N{EM DASH} the database now")
    assert summary(doc, "restart") == [("the\N{EM DASH}", 2, 3, "cutoff")]
    assert events_of(doc, "repetition") == []


def test_cutoff_at_the_end_has_no_repair() -> None:
    doc = analyze_script("we picked it for the bill-")
    [restart] = events_of(doc, "restart")
    assert restart["repair_word"] is None


def test_abandoned_phrase_with_a_break() -> None:
    doc = analyze_script("we need to |0.4| we should migrate the data")
    assert summary(doc, "restart") == [("we", 0, 3, "abandoned_phrase")]
    assert events_of(doc, "restart")[0]["repair_word"] == 3
    doc = analyze_script("we need to, we should migrate the data")
    assert summary(doc, "restart") == [("we", 0, 3, "abandoned_phrase")]


def test_repeated_start_words_without_a_break_are_not_restarts() -> None:
    assert events_of(analyze_script("we need to we should migrate"), "restart") == []
    assert events_of(analyze_script("we said |0.4| we would migrate"), "restart") == []


@pytest.mark.parametrize(
    ("script", "abandoned"),
    [
        ("We should |0.3| we need to rethink the whole approach", "We should"),
        ("I want to |0.4| I would start with the read path", "I want to"),
        ("we need the |0.4| we should migrate it soon", "we need the"),
    ],
)
def test_abandoned_phrase_the_repair_cannot_continue(script: str, abandoned: str) -> None:
    doc = analyze_script(script)
    [restart] = events_of(doc, "restart")
    texts = [w["text"] for w in doc["words"][restart["word_start"] : restart["word_end"]]]
    assert (" ".join(texts), restart["reason"]) == (abandoned, "abandoned_phrase")


@pytest.mark.parametrize(
    "script",
    [
        # After a conjunction or preposition the sentence goes on.
        "We moved the data because |0.4| the old system was slow.",
        "We built it and |0.4| we shipped it in two weeks.",
        "We did it before the end of |0.4| the quarter and it held.",
        "I checked the logs and, um, the metrics before launch.",
        # After a modal or auxiliary only a new subject restarts, and not inside an "if" clause.
        "If we could, |0.4| we would migrate everything today.",
        "Whatever it was, |0.4| it worked out fine for us.",
        "We want to |0.4| migrate the data before the end.",
    ],
)
def test_normal_speech_is_not_an_abandoned_phrase(script: str) -> None:
    doc = analyze_script(script)
    assert events_of(doc, "restart") == []
    assert [e for e in events_of(doc, "block") if e["reason"] == "before_restart"] == []


# --- Pauses ------------------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("script", "expected"),
    [
        ("we need joins. |0.7| Uh the team knew it", ("boundary_pause", "sentence")),
        ("we picked one database, |0.6| and it has worked", ("boundary_pause", "clause")),
        ("we picked Postgres |0.6| because the reports need joins", ("boundary_pause", "clause")),
        ("So |0.5| we picked Postgres for it", ("boundary_pause", "clause")),
        ("the |0.6| reporting queries need joins", ("block", "inside_phrase")),
        ("we chose it because, like, |0.6| the reports", ("block", "inside_phrase")),
        ("we chose it because... |0.6| the reports", ("block", "inside_phrase")),
        ("the queries need |0.6| uh joins for reports", ("block", "before_filler")),
        ("so we nee- |0.5| we picked Postgres", ("block", "before_restart")),
        ("so we picked |0.5| the the team", ("block", "before_restart")),
        # No sentence punctuation anywhere: a capital letter marks the sentence boundary.
        ("we need joins |0.7| The team knew it", ("boundary_pause", "sentence")),
        ("we need joins |0.7| I think the team knew", ("boundary_pause", "sentence")),
        ("we need joins and |0.7| more of them", ("block", "inside_phrase")),
        # With punctuation elsewhere, a capital still starts a sentence when the engine dropped
        # the period, unless the word looks like a name: inner capitals, a month, or a word
        # capitalized mid-sentence twice and never written in lower case.
        (
            "There are three. I would focus on |0.6| Reliability, cost",
            ("boundary_pause", "sentence"),
        ),
        ("We like it. we moved to |0.6| DynamoDB for billing", ("block", "inside_phrase")),
        ("We like Postgres. we moved to |0.6| Postgres for it", ("block", "inside_phrase")),
        ("We like it. we shipped it in |0.6| March for it", ("block", "inside_phrase")),
        ("It was fine. we said |0.6| I would do it", ("block", "inside_phrase")),
    ],
)
def test_pause_classification(script: str, expected: tuple[str, str]) -> None:
    doc = analyze_script(script)
    pauses = [
        (e["type"], e["reason"]) for e in doc["events"] if e["type"] in {"block", "boundary_pause"}
    ]
    assert pauses == [expected]


def test_pause_event_is_an_empty_range_before_the_next_word() -> None:
    doc = analyze_script("the |0.6| reporting queries need joins")
    [block] = events_of(doc, "block")
    assert (block["word_start"], block["word_end"]) == (1, 1)
    assert block["start"] == doc["words"][0]["end"]
    assert block["end"] == doc["words"][1]["start"]


def test_pause_threshold_is_250_ms() -> None:
    script = "we need joins. |{}| The team knew it"
    assert events_of(analyze_script(script.format(0.24)), "boundary_pause") == []
    assert len(events_of(analyze_script(script.format(0.25)), "boundary_pause")) == 1


def test_short_silence_inside_a_phrase_is_no_event() -> None:
    """250 ms counts a pause; getting stuck inside a phrase takes 500 ms. A shorter silence
    inside a phrase is neither a block nor a boundary pause."""
    script = "the |{}| reporting queries need joins"
    doc = analyze_script(script.format(0.49))
    assert [e for e in doc["events"] if e["type"] in {"block", "boundary_pause"}] == []
    assert (doc["metrics"]["blocks"]["count"], doc["metrics"]["boundary_pauses"]["count"]) == (0, 0)
    assert len(events_of(analyze_script(script.format(0.5)), "block")) == 1
    # Before a filler or a restart, 250 ms is enough: the hesitation shows in what follows.
    assert summary(analyze_script("the queries need |0.3| uh joins now"), "block") == [
        ("uh", 3, 3, "before_filler")
    ]


def test_silence_next_to_a_sound_is_not_a_pause() -> None:
    doc = analyze_script("the |0.6| (laughter) |0.6| reporting queries need joins")
    assert events_of(doc, "block") == []


def test_silence_before_the_first_word_is_not_an_event() -> None:
    doc = analyze_script("we picked Postgres for billing")
    assert doc["metrics"]["speech_start_s"] == 0.5
    assert [e for e in doc["events"] if e["type"] in {"block", "boundary_pause"}] == []


# --- Voice activity cross-check ----------------------------------------------------------------


def _with_speech(script: str, speech: list[tuple[float, float]], **timing: float) -> dict:
    words = words_from(script, **timing)
    acoustics = Acoustics(duration_s=words[-1].end + 0.5, speech=speech)
    return build_analysis(take_id="t", transcript=transcript_from(words), acoustics=acoustics)


def test_word_gap_with_voice_in_it_is_not_a_pause() -> None:
    # Words: the 0.5-0.7, reporting 1.3-1.5, ... The engine leaves a gap, but the voice never
    # stops (a drawn-out "theee").
    words = words_from("the |0.6| reporting queries need joins")
    speech = [(0.5, words[-1].end)]
    doc = _with_speech("the |0.6| reporting queries need joins", speech)
    assert events_of(doc, "block") == []


def test_pause_times_come_from_voice_activity() -> None:
    # The engine stretched "the" to 0.95 s, leaving a 0.15 s gap; the voice stopped at 0.55 s.
    words = words_from("the |0.15| reporting queries need joins", word_s=0.45)
    speech = [(0.5, 0.55), (words[1].start, words[-1].end)]
    doc = _with_speech("the |0.15| reporting queries need joins", speech, word_s=0.45)
    [block] = events_of(doc, "block")
    assert (block["start"], block["end"]) == (0.55, words[1].start)


def test_no_pause_when_the_engine_shows_no_gap() -> None:
    words = words_from("the reporting queries need joins", gap_s=0.0, word_s=0.45)
    speech = [(0.5, 0.7), (1.0, words[-1].end)]
    doc = _with_speech("the reporting queries need joins", speech, gap_s=0.0, word_s=0.45)
    assert events_of(doc, "block") == []


def test_untrusted_voice_track_falls_back_to_word_times() -> None:
    # Voice activity covers almost none of the words, so it is ignored.
    doc = _with_speech("the |0.6| reporting queries need joins", [(0.5, 0.55)])
    assert len(events_of(doc, "block")) == 1
    words = doc["words"]
    assert doc["metrics"]["voiced_s"] == round(sum(w["end"] - w["start"] for w in words), 2)


def test_word_the_voice_track_missed_keeps_the_engine_gap() -> None:
    # The track hears "reporting" onwards but not the quiet "the", so it cannot place the
    # silence; the engine's own gap is the pause, not everything since the start of "the".
    script = "the |0.6| reporting queries need joins and more"
    words = words_from(script)
    doc = _with_speech(script, [(words[1].start, words[-1].end)])
    [block] = events_of(doc, "block")
    assert (block["start"], block["end"]) == (words[0].end, words[1].start)


def test_events_are_sorted_with_sequential_ids() -> None:
    doc = analyze_script("So um we nee- we picked |0.6| uh the the team")
    starts = [(e["start"], e["word_start"]) for e in doc["events"]]
    assert starts == sorted(starts)
    assert [e["id"] for e in doc["events"]] == [f"e{n}" for n in range(len(doc["events"]))]
    assert {e["source"] for e in doc["events"]} == {"rules"}


# --- Hesitations -------------------------------------------------------------------------------


def test_silence_filler_silence_is_one_block() -> None:
    doc = analyze_script("the reason was |0.6| um |0.3| the cost of running it")
    [block] = events_of(doc, "block")
    words = doc["words"]
    assert (block["reason"], block["word_start"], block["word_end"]) == ("before_filler", 3, 3)
    # The block spans the whole hesitation: first silence, the filler, the last silence.
    assert (block["start"], block["end"]) == (words[2]["end"], words[4]["start"])
    assert doc["metrics"]["blocks"]["count"] == 1
    assert doc["metrics"]["blocks"]["longest_s"] == round(words[4]["start"] - words[2]["end"], 2)
    assert summary(doc, "filled_pause") == [("um", 3, 4, None)]


def test_two_hesitations_are_not_a_cluster() -> None:
    doc = analyze_script(
        "the reason was |0.6| um |0.3| the cost of it and it was just |0.5| uh |0.2| too high"
    )
    assert doc["metrics"]["blocks"]["count"] == 2
    assert doc["nervousness_signs"] == []


def test_long_boundary_hesitation_on_a_filler_is_a_block() -> None:
    # Silence, "um", silence between sentences: stuck between ideas once it reaches 1 s.
    doc = analyze_script("We shipped it in March. |0.9| Um, |0.5| and then the second one")
    assert summary(doc, "block") == [("Um,", 5, 5, "before_filler")]
    assert events_of(doc, "boundary_pause") == []
    doc = analyze_script("That was the first phase |1.2| Um |0.6| The second phase was long")
    assert summary(doc, "block") == [("Um", 5, 5, "before_filler")]


def test_short_boundary_hesitation_on_a_filler_stays_natural() -> None:
    doc = analyze_script("We shipped it in March. |0.3| um and then the second one")
    assert summary(doc, "boundary_pause") == [("um", 5, 5, "sentence")]
    assert events_of(doc, "block") == []
    assert summary(doc, "filled_pause") == [("um", 5, 6, None)]


def test_boundary_hesitation_without_a_filler_is_never_a_block() -> None:
    doc = analyze_script("We shipped it in March. |1.5| And then the second one came")
    assert summary(doc, "boundary_pause") == [("And", 5, 5, "sentence")]


def test_non_finite_confidence_is_null_and_the_document_is_json() -> None:
    words = words_from("we picked Postgres for billing")
    words = [
        Word(w.text, w.start, w.end, c)
        for w, c in zip(words, [math.nan, math.inf, -math.inf, 0.5, None], strict=True)
    ]
    acoustics = Acoustics(
        duration_s=3.0,
        speech=[],
        pitch_times=np.arange(0, 3, 0.01),
        pitch_hz=np.full(300, np.nan),
        intensity_times=np.arange(0, 3, 0.01),
        intensity_db=np.full(300, np.nan),
    )
    doc = build_analysis(take_id="t", transcript=transcript_from(words), acoustics=acoustics)
    assert [w["confidence"] for w in doc["words"]] == [None, None, None, 0.5, None]
    assert doc["metrics"]["pitch"] is None and doc["metrics"]["volume"] is None
    json.dumps(doc, allow_nan=False)
