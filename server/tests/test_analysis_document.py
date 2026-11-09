"""The analysis document as a whole: its shape against the contract example, NoSpeech, metrics,
nervousness signs, finalization and metric comparison."""

from __future__ import annotations

import copy
from pathlib import Path
from typing import Any

import numpy as np
import pytest
import soundfile
from analysis_helpers import analyze_script, events_of, load_fixture, transcript_from, words_from

from speakup.analysis import NoSpeech, analyze, build_analysis, compare_metrics, finalize
from speakup.analysis.acoustics import Acoustics
from speakup.audio import SAMPLE_RATE
from speakup.stt import Transcript, Word

EXAMPLE = load_fixture("analysis_example.json")
COACHING = load_fixture("coaching_example.json")


def _example_transcript() -> Transcript:
    words = [Word(w["text"], w["start"], w["end"], w["confidence"]) for w in EXAMPLE["words"]]
    return transcript_from(words)


def _buzz_wav(path: Path, words: list[Word], seconds: float) -> Path:
    """A voice-like buzz (120 Hz with harmonics) during each word, silence elsewhere."""
    samples = np.zeros(round(seconds * SAMPLE_RATE), dtype=np.float32)
    for w in words:
        a, b = round(w.start * SAMPLE_RATE), round(w.end * SAMPLE_RATE)
        phase = 2 * np.pi * 120 * np.arange(a, b) / SAMPLE_RATE
        buzz = sum(np.sin(k * phase) / k for k in range(1, 15))
        samples[a:b] = 0.2 * buzz * np.hanning(b - a)
    soundfile.write(path, samples, SAMPLE_RATE, subtype="PCM_16")
    return path


def _shape(value: Any) -> Any:
    """Keys and value types, with lists reduced to the shape of their items."""
    if isinstance(value, dict):
        return {k: _shape(v) for k, v in value.items()}
    if isinstance(value, list):
        return [_shape(v) for v in value[:1]]
    if isinstance(value, bool) or value is None:
        return type(value).__name__
    if isinstance(value, int | float):
        return "number"
    return type(value).__name__


# --- Shape against the contract example --------------------------------------------------------


def test_analyze_matches_the_contract_example_shape(tmp_path: Path) -> None:
    transcript = _example_transcript()
    wav = _buzz_wav(tmp_path / "take.wav", transcript.words, 9.5)
    doc = analyze(take_id=EXAMPLE["take_id"], wav16k=wav, transcript=transcript)

    assert list(doc) == list(EXAMPLE)
    assert doc["schema_version"] == "analysis/1"
    assert doc["created_at"].endswith("Z")
    assert doc["coaching_applied"] is False
    assert _shape(doc["provenance"]) == _shape(EXAMPLE["provenance"]) | {
        "stt": {"engine": "str", "model": "str", "version": "NoneType"}
    }
    assert doc["words"] == EXAMPLE["words"]

    event_keys = list(EXAMPLE["events"][0])
    nullable = {k for e in EXAMPLE["events"] for k, v in e.items() if v is None}
    for e in doc["events"]:
        assert list(e) == event_keys
        for key in event_keys:
            if e[key] is None:
                assert key in nullable, key

    # Nested metric keys and types match; values differ (the example is a 96-second take).
    assert _shape(doc["metrics"]) == _shape(EXAMPLE["metrics"]) | {
        "fillers": _shape(EXAMPLE["metrics"]["fillers"]) | {"resolution": "str"}
    }
    assert doc["metrics"]["fillers"]["resolution"] == "rules"
    assert len(doc["metrics"]["pace"]["by_quarter_wpm"]) == 4
    # Under 20 seconds of speech there are no quarter-based signs, and there are two blocks only.
    assert doc["nervousness_signs"] == []


def test_example_events_from_rules() -> None:
    """The rules events for the example's 18 words, measured without audio so the pauses are
    the word gaps. They match the example's events except where the example, cut by hand,
    leaves out what the documented rules imply: the "So" candidate (not a filler: no silence
    after it), the 250 ms pause after "um" (a natural beat after a sentence-initial "So"), and
    the pause between "nee-" and its repair (a block before a restart)."""
    acoustics = Acoustics(duration_s=9.5, speech=[])
    doc = build_analysis(take_id="t", transcript=_example_transcript(), acoustics=acoustics)
    got = [
        (e["type"], e["start"], e["end"], e["word_start"], e["word_end"], e["reason"],
         e["repair_word"], e["is_filler"])
        for e in doc["events"]
    ]  # fmt: skip
    example = {
        e["id"]: (
            e["type"], e["start"], e["end"], e["word_start"], e["word_end"], e["reason"],
            e["repair_word"], e["is_filler"],
        )
        for e in EXAMPLE["events"]
    }  # fmt: skip
    assert got == [
        ("lexical_filler", 0.84, 1.02, 0, 1, None, None, False),
        example["e0"],
        ("boundary_pause", 1.46, 1.71, 2, 2, "clause", None, None),
        example["e1"],
        ("block", 2.02, 2.45, 4, 4, "before_restart", None, None),
        example["e2"],
        example["e3"],
        example["e4"],
        example["e5"],
        example["e6"],
    ]
    assert events_of(doc, "lexical_filler")[1]["filler_resolution"] == "rules"


# --- NoSpeech ----------------------------------------------------------------------------------


def test_no_speech_under_five_words(tmp_path: Path) -> None:
    with pytest.raises(NoSpeech):
        analyze_script("um we uh need it hmm")
    words = words_from("um hello there uh")
    with pytest.raises(NoSpeech):
        # Raised before the audio is read, so a missing file does not matter.
        analyze(take_id="t", wav16k=tmp_path / "missing.wav", transcript=transcript_from(words))
    assert analyze_script("we need it right now")["metrics"]["word_count"] == 5


# --- Metrics -----------------------------------------------------------------------------------


def test_event_metrics() -> None:
    doc = analyze_script(
        "So um we nee- we picked Postgres because, like, |1.0| the reporting queries need "
        "joins. |0.7| Uh the the team |0.5| and it has worked well for us. |0.3| We like it"
    )
    m = doc["metrics"]
    assert m["word_count"] == 26
    assert m["fillers"] == {
        "filled_pauses": 2,
        "lexical": 1,
        "lexical_candidates": 2,
        "per_100_words": 11.54,
        "resolution": "rules",
    }
    assert m["blocks"]["count"] == 1
    assert m["blocks"]["longest_s"] == m["blocks"]["total_s"] == 1.0
    assert m["blocks"]["per_minute"] == round(60 / m["speaking_s"], 2)
    assert m["boundary_pauses"] == {"count": 3, "median_s": 0.5}
    assert (m["restarts"], m["repetitions"]) == (1, 1)
    words = doc["words"]
    assert m["speech_start_s"] == words[0]["start"]
    assert m["speaking_s"] == round(words[-1]["end"] - words[0]["start"], 2)


def _steady_take(seconds: float, last_quarter_gap: float = 0.05) -> list[Word]:
    """A take of 0.2 s words; the gaps in the last quarter can be changed."""
    words, t = [], 0.5
    while t < seconds:
        words.append(Word("word", round(t, 3), round(t + 0.2, 3), 0.9))
        t += 0.2 + (0.05 if t < 0.5 + 0.75 * seconds else last_quarter_gap)
    return words


def test_pace_metrics_use_voiced_time() -> None:
    words = _steady_take(40)
    speech = [(words[0].start, words[-1].end)]
    acoustics = Acoustics(duration_s=41, speech=speech)
    doc = build_analysis(take_id="t", transcript=transcript_from(words), acoustics=acoustics)
    m = doc["metrics"]
    assert m["voiced_s"] == m["speaking_s"]
    assert m["pace"]["wpm_voiced"] == m["pace"]["wpm_speaking"]
    assert all(abs(q - 240) < 10 for q in m["pace"]["by_quarter_wpm"])
    assert m["pitch"] is None and m["volume"] is None


def test_pace_rise_sign() -> None:
    # Voice track: the words only, so voiced pace is constant unless words get denser.
    slow = _steady_take(40, last_quarter_gap=0.05)
    fast_end = [Word(w.text, w.start, w.end, w.confidence) for w in slow]
    # Shrink the words of the last quarter: same count per voiced second goes up.
    span_end = fast_end[-1].end
    cut = fast_end[0].start + 0.75 * (span_end - fast_end[0].start)
    fast_end = [
        Word(w.text, w.start, round(w.start + (0.15 if w.start >= cut else 0.2), 3), 0.9)
        for w in fast_end
    ]
    speech = [(w.start, w.end) for w in fast_end]
    acoustics = Acoustics(duration_s=41, speech=speech)
    doc = build_analysis(take_id="t", transcript=transcript_from(fast_end), acoustics=acoustics)
    [sign] = doc["nervousness_signs"]
    assert sign["type"] == "pace_rise"
    assert sign["value"] >= 15
    assert sign["detail"].startswith("Pace rose ")
    assert sign["start"] == round(doc["metrics"]["speech_start_s"] + 0.75 * doc["metrics"][
        "speaking_s"], 2)  # fmt: skip


def test_no_quarter_signs_under_20_seconds() -> None:
    words = _steady_take(15)
    speech = [(w.start, w.end if w.start < 10 else w.start + 0.1) for w in words]
    acoustics = Acoustics(duration_s=16, speech=speech)
    doc = build_analysis(take_id="t", transcript=transcript_from(words), acoustics=acoustics)
    assert doc["metrics"]["pace"]["by_quarter_wpm"][3] > doc["metrics"]["pace"]["by_quarter_wpm"][0]
    assert doc["nervousness_signs"] == []


def test_block_cluster_sign() -> None:
    doc = analyze_script(
        "the |0.5| reporting queries |0.5| need many |0.5| joins on the data we store "
        "for the |0.5| billing team"
    )
    assert doc["metrics"]["blocks"]["count"] == 4
    [sign] = doc["nervousness_signs"]
    assert (sign["type"], sign["value"]) == ("block_cluster", 4)
    blocks = events_of(doc, "block")
    assert (sign["start"], sign["end"]) == (blocks[0]["start"], blocks[-1]["end"])


def test_two_blocks_are_not_a_cluster() -> None:
    doc = analyze_script("the |0.5| reporting queries |0.5| need many joins on the data")
    assert doc["nervousness_signs"] == []


def _pitch_acoustics(words: list[Word], start_hz: float, end_hz: float) -> Acoustics:
    end = words[-1].end
    times = np.arange(0, end + 0.5, 0.01)
    hz = np.where(
        (times >= words[0].start) & (times <= end),
        start_hz + (end_hz - start_hz) * (times - words[0].start) / (end - words[0].start),
        0.0,
    )
    db = np.full(len(times), 60.0) + 3 * np.sin(times)
    return Acoustics(
        duration_s=end + 0.5,
        speech=[(words[0].start, end)],
        pitch_times=times,
        pitch_hz=hz,
        intensity_times=times,
        intensity_db=db,
    )


def test_pitch_and_volume_metrics_and_pitch_rise() -> None:
    words = _steady_take(30)
    acoustics = _pitch_acoustics(words, 110.0, 150.0)
    doc = build_analysis(take_id="t", transcript=transcript_from(words), acoustics=acoustics)
    pitch, volume = doc["metrics"]["pitch"], doc["metrics"]["volume"]
    assert 125 < pitch["median_hz"] < 135
    q = pitch["by_quarter_median_hz"]
    assert q == sorted(q) and q[0] < 120 < 140 < q[3]
    assert pitch["variation_st"] > 1 and pitch["range_st"] > 4
    assert 58 < volume["median_db"] < 62 and volume["variation_db"] > 1
    [sign] = doc["nervousness_signs"]
    assert sign["type"] == "pitch_rise" and sign["value"] >= 2
    assert "semitones" in sign["detail"]


def test_flat_pitch_has_no_pitch_rise() -> None:
    words = _steady_take(30)
    acoustics = _pitch_acoustics(words, 120.0, 121.0)
    doc = build_analysis(take_id="t", transcript=transcript_from(words), acoustics=acoustics)
    assert doc["metrics"]["pitch"]["variation_st"] < 0.2
    assert doc["nervousness_signs"] == []


# --- Finalization ------------------------------------------------------------------------------


def _stage() -> dict[str, Any]:
    script = (
        "So um we nee- we picked Postgres because, like, |1.0| the reporting queries need "
        "joins. |0.7| Uh the the team |0.5| and it has worked well for us. We like it, "
        "basically, for billing"
    )
    return analyze_script(script)


def _coaching(stage: dict[str, Any]) -> dict[str, Any]:
    report = copy.deepcopy(COACHING)
    lexical = events_of(stage, "lexical_filler")
    report["filler_rulings"] = [
        {"event_id": e["id"], "is_filler": stage["words"][e["word_start"]]["norm"] != "like"}
        for e in lexical
    ]
    report["annotations"] = [
        {"type": "off_topic", "word_start": 20, "word_end": 26, "note": "Off the question."},
        {"type": "restart", "word_start": 5, "word_end": 7, "note": "Changed course here."},
    ]
    return report


def test_finalize_without_coaching_returns_the_input_unchanged() -> None:
    stage = _stage()
    final = finalize(stage, None)
    assert final == stage and final is not stage
    assert final["coaching_applied"] is False


def test_finalize_applies_rulings_and_annotations() -> None:
    stage = _stage()
    before = copy.deepcopy(stage)
    report = _coaching(stage)
    final = finalize(stage, report)
    assert stage == before  # pure

    assert final["coaching_applied"] is True
    lexical = events_of(final, "lexical_filler")
    assert [(final["words"][e["word_start"]]["norm"], e["is_filler"]) for e in lexical] == [
        ("so", True),
        ("like", False),
        ("basically", True),
    ]
    assert {e["filler_resolution"] for e in lexical} == {"coaching"}

    added = [e for e in final["events"] if e["source"] == "coaching"]
    assert [(e["id"], e["type"], e["reason"], e["note"]) for e in added] == [
        ("c1", "restart", "self_correction", "Changed course here."),
        ("c0", "off_topic", None, "Off the question."),
    ]
    words = final["words"]
    off_topic = next(e for e in added if e["type"] == "off_topic")
    assert (off_topic["start"], off_topic["end"]) == (words[20]["start"], words[25]["end"])
    keys = list(stage["events"][0])
    assert all(list(e) == keys for e in final["events"])
    starts = [(e["start"], e["word_start"]) for e in final["events"]]
    assert starts == sorted(starts)

    fillers = final["metrics"]["fillers"]
    assert (fillers["lexical"], fillers["lexical_candidates"]) == (2, 3)
    assert fillers["resolution"] == "coaching"
    assert fillers["per_100_words"] == round((2 + 2) / final["metrics"]["word_count"] * 100, 2)
    assert final["metrics"]["restarts"] == stage["metrics"]["restarts"] + 1
    unchanged = ("pace", "pitch", "volume", "blocks", "voiced_s", "duration_s")
    assert all(final["metrics"][k] == stage["metrics"][k] for k in unchanged)


def test_filler_resolution_is_coaching_only_when_every_candidate_was_judged() -> None:
    stage = _stage()
    report = _coaching(stage)
    partial = finalize(stage, report | {"filler_rulings": report["filler_rulings"][:1]})
    assert partial["metrics"]["fillers"]["resolution"] == "rules"

    none = analyze_script("we picked Postgres for the billing service")
    assert none["metrics"]["fillers"]["resolution"] == "rules"
    coached = finalize(none, report | {"filler_rulings": [], "annotations": []})
    assert coached["metrics"]["fillers"]["resolution"] == "coaching"


def test_finalize_rejects_reports_that_do_not_fit() -> None:
    stage = _stage()
    report = _coaching(stage)
    filled = events_of(stage, "filled_pause")[0]["id"]
    for event_id in (filled, "e999"):
        with pytest.raises(ValueError):
            ruling = [{"event_id": event_id, "is_filler": True}]
            finalize(stage, report | {"filler_rulings": ruling})
    bad_range = [{"type": "off_topic", "word_start": 3, "word_end": 999, "note": "x"}]
    with pytest.raises(ValueError):
        finalize(stage, report | {"annotations": bad_range})
    with pytest.raises(ValueError):
        finalize(finalize(stage, report), report)


# --- Metric comparison -------------------------------------------------------------------------


def _metrics(per_100: float, blocks: int, restarts: int, repetitions: int) -> dict[str, Any]:
    doc = copy.deepcopy(EXAMPLE)
    m = doc["metrics"]
    m["fillers"]["per_100_words"] = per_100
    m["blocks"]["count"] = blocks
    m["restarts"], m["repetitions"] = restarts, repetitions
    return doc


def test_compare_metrics_order_and_directions() -> None:
    previous = _metrics(3.74, 4, 2, 3)
    current = _metrics(2.9, 1, 2, 4)
    current["metrics"]["pace"]["wpm_voiced"] = 171.4
    changes = compare_metrics(previous, current)
    assert [c["metric"] for c in changes] == [
        "fillers_per_100_words",
        "blocks",
        "restarts",
        "repetitions",
        "wpm_voiced",
        "duration_s",
        "pitch_variation_st",
        "volume_variation_db",
    ]
    assert [c["change"] for c in changes] == [
        "better", "better", "same", "worse", "info", "info", "info", "info",
    ]  # fmt: skip
    assert changes[0] == {
        "metric": "fillers_per_100_words",
        "label": "Fillers per 100 words",
        "unit": "per 100 words",
        "before": 3.74,
        "after": 2.9,
        "change": "better",
    }
    assert (changes[4]["before"], changes[4]["after"]) == (180.1, 171.4)


@pytest.mark.parametrize(
    ("before", "after", "change"),
    [
        (3.0, 3.29, "same"),  # under 10%
        (3.0, 2.71, "same"),
        (3.0, 3.3, "worse"),  # 10% or more
        (3.0, 2.7, "better"),
        (0.0, 0.0, "same"),
        (0.0, 0.5, "worse"),
    ],
)
def test_filler_rate_band(before: float, after: float, change: str) -> None:
    changes = compare_metrics(_metrics(before, 1, 1, 1), _metrics(after, 1, 1, 1))
    assert changes[0]["change"] == change


@pytest.mark.parametrize(
    ("before", "after", "change"), [(2, 2, "same"), (2, 1, "better"), (2, 3, "worse")]
)
def test_counts_compare_exactly(before: int, after: int, change: str) -> None:
    changes = compare_metrics(
        _metrics(1.0, before, before, before), _metrics(1.0, after, after, after)
    )
    assert [c["change"] for c in changes[1:4]] == [change] * 3


def test_null_metrics_compare_as_info() -> None:
    previous, current = _metrics(1.0, 1, 1, 1), _metrics(1.0, 1, 1, 1)
    current["metrics"]["pitch"] = None
    changes = compare_metrics(previous, current)
    pitch = next(c for c in changes if c["metric"] == "pitch_variation_st")
    assert (pitch["before"], pitch["after"], pitch["change"]) == (2.3, None, "info")
    assert compare_metrics(previous, current) == changes  # pure and repeatable
