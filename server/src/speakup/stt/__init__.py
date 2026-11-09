"""Speech to text behind one interface.

Every engine returns verbatim words with start and end times in seconds. An engine must keep
fillers, repetitions and false starts; see docs/architecture.md#speech-to-text.
"""

from __future__ import annotations

import json
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Protocol


@dataclass(frozen=True)
class Word:
    text: str
    start: float
    end: float
    confidence: float | None = None


@dataclass
class Transcript:
    engine: str
    text: str
    words: list[Word]
    audio_seconds: float
    elapsed_seconds: float = 0.0
    raw: dict[str, Any] = field(default_factory=dict)

    def save(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(asdict(self), indent=2, ensure_ascii=False))

    @classmethod
    def load(cls, path: Path) -> Transcript:
        data = json.loads(path.read_text())
        data["words"] = [Word(**w) for w in data["words"]]
        return cls(**data)


class Engine(Protocol):
    name: str
    description: str
    cost_per_hour_usd: float

    def missing_config(self) -> str | None:
        """Why the engine cannot run here, or None when it can."""

    def prepare(self) -> None:
        """Load models or check access. Not counted in latency."""

    def transcribe(self, wav_path: Path, audio_seconds: float) -> Transcript:
        """Transcribe a 16 kHz mono WAV file verbatim."""
