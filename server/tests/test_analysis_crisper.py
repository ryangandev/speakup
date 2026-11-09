"""The rules on real engine output: crisper-turbo transcripts of takes synthesized with macOS
`say`, replayed with their saved voice-activity segments, so no audio or model is needed."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from speakup.analysis import build_analysis
from speakup.analysis.acoustics import Acoustics
from speakup.stt import Transcript

FIXTURES = Path(__file__).parent / "fixtures" / "crisper"
VAD = json.loads((FIXTURES / "vad.json").read_text())


def _analyze(name: str) -> dict:
    transcript = Transcript.load(FIXTURES / f"{name}.transcript.json")
    vad = VAD[name]
    acoustics = Acoustics(duration_s=vad["duration_s"], speech=[tuple(s) for s in vad["speech"]])
    return build_analysis(take_id=name, transcript=transcript, acoustics=acoustics)


def _marks(doc: dict) -> list[tuple[str, str, str]]:
    texts = [w["text"] for w in doc["words"]]
    return [
        (e["type"], e["reason"], texts[e["word_start"]])
        for e in doc["events"]
        if e["type"] in {"block", "restart"}
    ]


@pytest.mark.parametrize(
    ("name", "marks"),
    [
        # "We moved the data because [400 ms] the old system was slow. We built it and [400 ms]
        # we shipped it in two weeks. I checked the logs and um the metrics": normal speech.
        ("g1_conj_pause", []),
        # "was [600] um [300] the cost ... was just [500] uh [200] too high": two hesitations,
        # one block each, and no cluster.
        ("d2_um_midclause", [("block", "before_filler", "[UM]"),
                             ("block", "before_filler", "[UH]")]),
        # "March. [900] Um, [500] and then": stuck between ideas.
        ("d5_boundary_um", [("block", "before_filler", "[UM]"),
                            ("block", "before_filler", "[UH]")]),
        # "phase. [1200] Um [600] The second": one block, not two.
        ("g2_boundary_um_capital", [("block", "before_filler", "[UM]")]),
        # "We should [300] we need to ... I want to [400] I would ... because the [300] the".
        ("d6_abandoned", [
            ("restart", "abandoned_phrase", "We"),
            ("restart", "abandoned_phrase", "I"),
            ("block", "before_restart", "I"),
            ("block", "before_restart", "[UH]"),
        ]),
    ],
)  # fmt: skip
def test_crisper_takes(name: str, marks: list[tuple[str, str, str]]) -> None:
    doc = _analyze(name)
    assert _marks(doc) == marks
    assert doc["nervousness_signs"] == []
    json.dumps(doc, allow_nan=False)
