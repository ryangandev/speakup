"""Reference pauses from Silero voice activity detection.

This is a reference, not ground truth: VAD has its own error of a few tens of milliseconds, and it
cannot tell a silent pause from a very quiet word. It is independent of every engine, which makes
it a fair yardstick for comparing their word timings.
"""

from __future__ import annotations

from functools import cache
from pathlib import Path

import soundfile
import torch

from speakup.audio import SAMPLE_RATE
from speakup.bakeoff.metrics import MIN_PAUSE_SECONDS, Gap


@cache
def _model():
    from silero_vad import load_silero_vad

    return load_silero_vad()


def speech_segments(wav_path: Path) -> list[tuple[float, float]]:
    from silero_vad import get_speech_timestamps

    samples, rate = soundfile.read(str(wav_path), dtype="float32")
    if rate != SAMPLE_RATE:
        raise ValueError(f"{wav_path} is {rate} Hz; convert it to {SAMPLE_RATE} Hz first")
    segments = get_speech_timestamps(
        torch.from_numpy(samples),
        _model(),
        sampling_rate=SAMPLE_RATE,
        min_silence_duration_ms=100,
        speech_pad_ms=0,
        return_seconds=True,
        time_resolution=3,
    )
    return [(s["start"], s["end"]) for s in segments]


def reference_pauses(wav_path: Path, min_length: float = MIN_PAUSE_SECONDS) -> list[Gap]:
    segments = speech_segments(wav_path)
    return [
        Gap(a_end, b_start)
        for (_, a_end), (b_start, _) in zip(segments, segments[1:], strict=False)
        if b_start - a_end >= min_length
    ]
