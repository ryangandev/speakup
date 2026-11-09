"""`analyze` on real synthesized speech: Silero VAD and Parselmouth run on audio made with macOS
`say`, against a transcript whose word times are known because the test placed every word."""

from __future__ import annotations

import json
import shutil
import subprocess
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np
import pytest
import soundfile

from speakup.analysis import Thresholds, analyze
from speakup.analysis.acoustics import measure, read_wav16k
from speakup.analysis.events import voice_track
from speakup.audio import SAMPLE_RATE
from speakup.stt import Transcript, Word

FIXTURE = Path(__file__).parent / "fixtures" / "say_take.json"

pytestmark = pytest.mark.skipif(shutil.which("say") is None, reason="needs macOS say")


def _synthesize(text: str, path: Path) -> np.ndarray:
    subprocess.run(
        ["say", "-o", str(path), "--file-format=WAVE", f"--data-format=LEI16@{SAMPLE_RATE}", text],
        check=True,
    )
    samples = read_wav16k(path)
    loud = np.flatnonzero(np.abs(samples) > 0.02 * np.abs(samples).max())
    return samples[loud[0] : loud[-1] + 1]


@pytest.fixture(scope="module")
def take(tmp_path_factory: pytest.TempPathFactory) -> tuple[Path, Transcript]:
    plan = json.loads(FIXTURE.read_text())
    tmp = tmp_path_factory.mktemp("say")
    entries = plan["words"]
    with ThreadPoolExecutor(max_workers=8) as pool:
        clips = list(
            pool.map(
                lambda n: _synthesize(entries[n].get("say", entries[n]["text"]), tmp / f"{n}.wav"),
                range(len(entries)),
            )
        )

    pieces, words, cursor = [], [], 0.0

    def silence(seconds: float) -> None:
        nonlocal cursor
        pieces.append(np.zeros(round(seconds * SAMPLE_RATE), dtype=np.float32))
        cursor += len(pieces[-1]) / SAMPLE_RATE

    silence(plan["lead_silence_s"])
    for n, (entry, clip) in enumerate(zip(entries, clips, strict=True)):
        if n:
            silence(entry.get("gap_before_s", plan["default_gap_s"]))
        start = cursor
        pieces.append(clip)
        cursor += len(clip) / SAMPLE_RATE
        words.append(Word(entry["text"], round(start, 3), round(cursor, 3), 0.99))
    silence(plan["trail_silence_s"])

    wav = tmp / "take.wav"
    soundfile.write(wav, np.concatenate(pieces), SAMPLE_RATE, subtype="PCM_16")
    text = " ".join(w.text for w in words)
    return wav, Transcript("crisper-large", text, words, audio_seconds=cursor)


def test_analyze_synthesized_take(take: tuple[Path, Transcript]) -> None:
    wav, transcript = take
    doc = analyze(take_id="say-take", wav16k=wav, transcript=transcript)
    texts = [w["text"] for w in doc["words"]]
    by_type: dict[str, list[dict]] = {}
    for e in doc["events"]:
        by_type.setdefault(e["type"], []).append(e)

    def at(e: dict) -> str:
        return texts[e["word_start"]]

    # Every designed pause is found and classified; nothing else is.
    blocks = [(at(e), e["reason"]) for e in by_type["block"]]
    assert blocks == [
        ("the", "inside_phrase"),
        ("uh", "before_filler"),
        ("we", "before_restart"),
    ]
    boundaries = [(at(e), e["reason"]) for e in by_type["boundary_pause"]]
    assert boundaries == [("Um", "sentence"), ("We", "sentence"), ("and", "clause")]
    long_block = by_type["block"][0]
    assert 0.8 <= long_block["end"] - long_block["start"] <= 1.0

    assert [at(e) for e in by_type["filled_pause"]] == ["uh", "Um"]
    [repetition] = by_type["repetition"]
    assert (repetition["word_start"], repetition["word_end"]) == (13, 15)
    [restart] = by_type["restart"]
    assert (restart["reason"], restart["word_start"], restart["repair_word"]) == ("cutoff", 19, 21)
    assert [(at(e), e["is_filler"]) for e in by_type["lexical_filler"]] == [
        ("So", False),
        ("like,", True),
    ]

    # The voice-activity track, not the word times, drove the pauses and voiced time.
    _, trusted = voice_track(doc["words"], measure(wav).speech, Thresholds())
    assert trusted

    metrics = doc["metrics"]
    assert metrics["word_count"] == 27
    # Voice activity, not word times: voiced time is below speaking time but most of it.
    assert 0.6 * metrics["speaking_s"] < metrics["voiced_s"] < metrics["speaking_s"]
    assert metrics["pace"]["wpm_voiced"] > metrics["pace"]["wpm_speaking"]
    assert metrics["pitch"] is not None and 60 < metrics["pitch"]["median_hz"] < 400
    assert metrics["volume"] is not None
    assert metrics["blocks"]["count"] == 3
