"""CrisperWhisper 2.0, run locally.

Docs: https://github.com/nyrahealth/CrisperWhisper
The model weights are licensed for non-commercial use only, which suits personal use.
On macOS only the PyTorch (transformers) backend is available; it runs on the GPU through MPS.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

from speakup.config import setting
from speakup.stt import Transcript, Word


class CrisperWhisperEngine:
    cost_per_hour_usd = 0.0

    def __init__(self, size: str) -> None:
        self.size = size
        self.name = f"crisper-{size}"
        self.description = f"CrisperWhisper 2.0 {size} (local)"
        self._model: Any = None

    def missing_config(self) -> str | None:
        try:
            import crisperwhisper  # noqa: F401
        except ImportError:
            return "install it with: uv sync --extra crisper"
        return None

    def prepare(self) -> None:
        if self._model is not None:
            return
        from crisperwhisper import CrisperWhisperModel

        device = setting("SPEAKUP_CRISPER_DEVICE", "mps")
        compute_type = "float16" if device != "cpu" else "float32"
        self._model = CrisperWhisperModel(
            self.size, backend="transformers", device=device, compute_type=compute_type
        )

    def transcribe(self, wav_path: Path, audio_seconds: float) -> Transcript:
        self.prepare()
        result = self._model.transcribe(
            str(wav_path), language="en", mode="verbatim", word_confidence=True
        )
        words = [
            Word(
                text=w.word,
                start=float(w.start),
                end=float(w.end),
                confidence=getattr(w, "probability", None),
            )
            for w in result.words or []
        ]
        return Transcript(
            engine=self.name,
            text=result.text,
            words=words,
            audio_seconds=audio_seconds,
        )
