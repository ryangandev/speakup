"""Audio file helpers."""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import soundfile

AUDIO_SUFFIXES = {".m4a", ".wav", ".mp3", ".aac", ".caf", ".aiff", ".flac", ".mp4", ".mov"}
SAMPLE_RATE = 16_000


def to_wav16k(src: Path, dst: Path) -> Path:
    """Convert any audio file to 16 kHz mono 16-bit PCM WAV, the input every engine accepts."""
    dst.parent.mkdir(parents=True, exist_ok=True)
    if shutil.which("ffmpeg"):
        cmd = [
            "ffmpeg",
            "-nostdin",
            "-loglevel",
            "error",
            "-y",
            "-i",
            str(src),
            "-ac",
            "1",
            "-ar",
            str(SAMPLE_RATE),
            "-sample_fmt",
            "s16",
            str(dst),
        ]
    else:
        cmd = [
            "afconvert",
            "-f",
            "WAVE",
            "-d",
            f"LEI16@{SAMPLE_RATE}",
            "-c",
            "1",
            str(src),
            str(dst),
        ]
    subprocess.run(cmd, check=True)
    return dst


def duration_seconds(path: Path) -> float:
    info = soundfile.info(str(path))
    return info.frames / info.samplerate
