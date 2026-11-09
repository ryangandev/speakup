"""Post-parse checks the structured-output schema cannot express."""

from __future__ import annotations

import json

import pytest
from coaching_helpers import analysis_example, output_example

from speakup.coaching.validate import tokens, validate_output


def _check(output: dict, *, fillers: list[str] | None = None, previous: int | None = None):
    return validate_output(
        json.dumps(output),
        words=analysis_example()["words"],
        lexical_filler_ids=["e2"] if fillers is None else fillers,
        previous_focus_count=previous,
    )


def test_tokens_ignore_case_punctuation_and_cutoffs() -> None:
    assert tokens("We nee- we picked, “Postgres” because’s") == [
        "we",
        "nee",
        "we",
        "picked",
        "postgres",
        "because's",
    ]


def test_example_output_is_valid() -> None:
    output, errors = _check(output_example())
    assert errors == []
    assert output is not None


@pytest.mark.parametrize("count", [0, 3])
def test_focus_must_have_one_or_two_items(count: int) -> None:
    out = output_example()
    out["focus"] = (out["focus"] * 2)[:count]
    _, errors = _check(out)
    assert f"focus: give 1 or 2 items, not {count}." in errors


def test_focus_evidence_must_have_one_to_three_anchors() -> None:
    out = output_example()
    out["focus"][0]["evidence"] = out["focus"][0]["evidence"] * 4
    _, errors = _check(out)
    assert "focus[0].evidence: give 1 to 3 anchors, not 4." in errors


def test_quote_not_in_transcript_is_an_error() -> None:
    out = output_example()
    out["strength"]["anchor"]["quote"] = "we chose MySQL"
    _, errors = _check(out)
    assert any(e.startswith('strength.anchor: the quote "we chose MySQL"') for e in errors)


def test_empty_range_with_matching_quote_is_repaired() -> None:
    out = output_example()
    out["strength"]["anchor"].update(word_start=4, word_end=4)
    output, errors = _check(out)
    assert errors == []
    assert (output.strength.anchor.word_start, output.strength.anchor.word_end) == (4, 8)


def test_repair_picks_the_occurrence_nearest_the_claimed_range() -> None:
    # "the" appears at words 9 and 15 (and in the padding); the claim points near 15.
    out = output_example()
    out["focus"][0]["evidence"] = [{"quote": "the", "word_start": 14, "word_end": 15}]
    output, errors = _check(out)
    assert errors == []
    assert output.focus[0].evidence[0].word_start == 15


def test_outline_and_annotation_ranges_are_checked() -> None:
    out = output_example()
    out["outline"]["points"][0]["word_end"] = 0
    out["annotations"][0]["word_end"] = 500
    _, errors = _check(out)
    assert any(e.startswith("outline.points[0]: word range 0 to 0") for e in errors)
    assert any(e.startswith("annotations[0]: word range 74 to 500") for e in errors)


def test_filler_rulings_must_match_the_lexical_filler_events() -> None:
    out = output_example()
    out["filler_rulings"] = [
        {"event_id": "e2", "is_filler": True},
        {"event_id": "e2", "is_filler": False},
        {"event_id": "e0", "is_filler": True},
    ]
    _, errors = _check(out, fillers=["e2", "e9"])
    assert "filler_rulings: missing rulings for e9." in errors
    assert any(e.startswith("filler_rulings: e0 are not lexical filler events") for e in errors)
    assert "filler_rulings: rule once on each of e2." in errors


def test_markdown_and_empty_text_are_rejected() -> None:
    out = output_example()
    out["verdict"] = "**Good** answer."
    out["reference_version"]["text"] = "We chose Postgres.\n\n- First, joins."
    out["focus"][0]["title"] = "  "
    _, errors = _check(out)
    assert "verdict: write plain text, without Markdown or bullet characters." in errors
    assert (
        "reference_version.text: write plain text, without Markdown or bullet characters." in errors
    )
    assert "focus[0].title: must not be empty." in errors


def test_schema_violations_are_reported_by_path() -> None:
    out = output_example()
    out["dimensions"]["close"]["level"] = "weak"
    del out["verdict"]
    output, errors = _check(out)
    assert output is None
    assert any(e.startswith("verdict:") for e in errors)
    assert any(e.startswith("dimensions.close.level:") for e in errors)


def test_focus_outcomes_are_sorted_by_previous_index() -> None:
    out = output_example()
    out["comparison"] = {
        "summary": "Better.",
        "focus_outcomes": [
            {"previous_focus_index": 1, "outcome": "improved", "evidence": "Yes.", "anchor": None},
            {
                "previous_focus_index": 0,
                "outcome": "not_improved",
                "evidence": "No.",
                "anchor": {"quote": "we picked", "word_start": 4, "word_end": 6},
            },
        ],
    }
    output, errors = _check(out, previous=2)
    assert errors == []
    assert [o.previous_focus_index for o in output.comparison.focus_outcomes] == [0, 1]
