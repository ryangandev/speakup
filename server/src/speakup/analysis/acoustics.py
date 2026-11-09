"""Measurements taken from the audio itself, independent of any speech-to-text engine.

Silero VAD gives the voice-activity track; Parselmouth (Praat) gives pitch and intensity.
Everything downstream works on the `Acoustics` value, so the rules can be tested with
hand-built measurements and no audio.
"""

from __future__ import annotations

import warnings
from dataclasses import dataclass, field
from functools import cache
from pathlib import Path

import numpy as np
import soundfile

from speakup.audio import SAMPLE_RATE

FRAME_STEP_S = 0.01
# Pitch search range. 75 Hz is Praat's default floor and suits a low male voice; 500 Hz keeps
# octave jumps on breathy or creaky frames out without cutting off raised speech.
PITCH_FLOOR_HZ = 75.0
PITCH_CEILING_HZ = 500.0


@dataclass(frozen=True)
class Acoustics:
    duration_s: float
    # Voice-activity segments, (start, end) in seconds, in order.
    speech: list[tuple[float, float]]
    # Frame times and values. Pitch is 0 Hz on unvoiced frames.
    pitch_times: np.ndarray = field(default_factory=lambda: np.zeros(0))
    pitch_hz: np.ndarray = field(default_factory=lambda: np.zeros(0))
    intensity_times: np.ndarray = field(default_factory=lambda: np.zeros(0))
    intensity_db: np.ndarray = field(default_factory=lambda: np.zeros(0))


@cache
def _vad_model():
    from silero_vad import load_silero_vad

    # silero-vad 6.2 loads its model with torch.jit.load, which torch 2.15 deprecates.
    # Nothing to change on our side until silero-vad moves off it.
    with warnings.catch_warnings():
        warnings.filterwarnings("ignore", message=".*torch.jit.load.*", category=FutureWarning)
        return load_silero_vad()


def read_wav16k(wav_path: Path) -> np.ndarray:
    samples, rate = soundfile.read(str(wav_path), dtype="float32", always_2d=False)
    if rate != SAMPLE_RATE:
        raise ValueError(f"{wav_path} is {rate} Hz; convert it to {SAMPLE_RATE} Hz first")
    if samples.ndim > 1:
        samples = samples.mean(axis=1)
    return samples


def speech_segments(samples: np.ndarray) -> list[tuple[float, float]]:
    """Voice-activity segments of 16 kHz mono samples, in seconds.

    Silences shorter than 100 ms are merged into speech and segments are not padded, so the
    gaps between segments are the silences themselves.
    """
    import torch
    from silero_vad import get_speech_timestamps

    segments = get_speech_timestamps(
        torch.from_numpy(np.ascontiguousarray(samples, dtype=np.float32)),
        _vad_model(),
        sampling_rate=SAMPLE_RATE,
        min_silence_duration_ms=100,
        speech_pad_ms=0,
        return_seconds=True,
        time_resolution=3,
    )
    return [(float(s["start"]), float(s["end"])) for s in segments]


def measure(wav_path: Path) -> Acoustics:
    import parselmouth

    samples = read_wav16k(wav_path)
    sound = parselmouth.Sound(samples.astype(np.float64), sampling_frequency=SAMPLE_RATE)
    pitch = sound.to_pitch_ac(
        time_step=FRAME_STEP_S, pitch_floor=PITCH_FLOOR_HZ, pitch_ceiling=PITCH_CEILING_HZ
    )
    # Praat needs at least 6.4 / minimum_pitch seconds of audio for an intensity frame.
    if sound.duration > 6.4 / PITCH_FLOOR_HZ:
        intensity = sound.to_intensity(minimum_pitch=PITCH_FLOOR_HZ, time_step=FRAME_STEP_S)
        intensity_times, intensity_db = np.asarray(intensity.xs()), intensity.values[0]
    else:
        intensity_times, intensity_db = np.zeros(0), np.zeros(0)
    return Acoustics(
        duration_s=len(samples) / SAMPLE_RATE,
        speech=speech_segments(samples),
        pitch_times=np.asarray(pitch.xs()),
        pitch_hz=np.asarray(pitch.selected_array["frequency"]),
        intensity_times=intensity_times,
        intensity_db=np.asarray(intensity_db),
    )
