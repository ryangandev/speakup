"""Reference pauses from Silero voice activity detection.

This is a reference, not ground truth: VAD has its own error of a few tens of milliseconds, and it
cannot tell a silent pause from a very quiet word. It is independent of every engine, which makes
it a fair yardstick for comparing their word timings. The voice-activity track itself belongs to
the analysis module, so the bake-off measures engines against the same track the app uses.
"""

from __future__ import annotations

from pathlib import Path

from speakup.analysis import acoustics
from speakup.bakeoff.metrics import MIN_PAUSE_SECONDS, Gap


def speech_segments(wav_path: Path) -> list[tuple[float, float]]:
    return acoustics.speech_segments(acoustics.read_wav16k(wav_path))


def reference_pauses(wav_path: Path, min_length: float = MIN_PAUSE_SECONDS) -> list[Gap]:
    segments = speech_segments(wav_path)
    return [
        Gap(a_end, b_start)
        for (_, a_end), (b_start, _) in zip(segments, segments[1:], strict=False)
        if b_start - a_end >= min_length
    ]
