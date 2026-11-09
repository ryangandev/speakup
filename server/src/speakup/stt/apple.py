"""Apple SpeechTranscriber (SpeechAnalyzer), on device.

The iPhone app may use the same framework, so this measures what on-device transcription keeps.
It runs through the Swift command-line tool in tools/apple-transcribe.
"""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

from speakup.config import REPO_DIR
from speakup.stt import Transcript, Word

PACKAGE_DIR = REPO_DIR / "tools" / "apple-transcribe"
BINARY = PACKAGE_DIR / ".build" / "release" / "apple-transcribe"


class AppleEngine:
    name = "apple"
    description = "Apple SpeechTranscriber (on device)"
    cost_per_hour_usd = 0.0

    def missing_config(self) -> str | None:
        if BINARY.exists():
            return None
        return f"build it with: swift build -c release --package-path {PACKAGE_DIR}"

    def prepare(self) -> None:
        pass

    def transcribe(self, wav_path: Path, audio_seconds: float) -> Transcript:
        completed = subprocess.run(
            [str(BINARY), str(wav_path), "en-US"], check=True, capture_output=True, text=True
        )
        body = json.loads(completed.stdout)
        return parse_output(body, audio_seconds)


def parse_output(body: dict, audio_seconds: float) -> Transcript:
    """Each item is one attributed-string run. A run usually holds one word; when it holds more,
    every word in it gets the run's time range, which the report notes as a timing limitation."""
    words: list[Word] = []
    for run in body.get("runs", []):
        for token in run["text"].split():
            words.append(
                Word(
                    text=token, start=run["start"], end=run["end"], confidence=run.get("confidence")
                )
            )
    return Transcript(
        engine=AppleEngine.name,
        text=body.get("text", ""),
        words=words,
        audio_seconds=audio_seconds,
        raw=body,
    )
