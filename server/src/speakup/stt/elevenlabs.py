"""ElevenLabs Scribe v2, batch API.

Docs: https://elevenlabs.io/docs/api-reference/speech-to-text/convert
Scribe keeps fillers and false starts unless `no_verbatim` is true.
"""

from __future__ import annotations

import math
from pathlib import Path

import httpx

from speakup.config import setting
from speakup.stt import Transcript, Word

URL = "https://api.elevenlabs.io/v1/speech-to-text"


class ScribeEngine:
    name = "scribe"
    description = "ElevenLabs Scribe v2 (cloud)"
    cost_per_hour_usd = 0.22

    def __init__(self, client: httpx.Client | None = None) -> None:
        self._client = client

    def missing_config(self) -> str | None:
        return None if setting("ELEVENLABS_API_KEY") else "set ELEVENLABS_API_KEY in server/.env"

    def prepare(self) -> None:
        pass

    def transcribe(self, wav_path: Path, audio_seconds: float) -> Transcript:
        client = self._client or httpx.Client(timeout=600)
        with wav_path.open("rb") as audio:
            response = client.post(
                URL,
                headers={"xi-api-key": setting("ELEVENLABS_API_KEY") or ""},
                data={
                    "model_id": "scribe_v2",
                    "language_code": "en",
                    "timestamps_granularity": "word",
                    "tag_audio_events": "true",
                    "no_verbatim": "false",
                },
                files={"file": (wav_path.name, audio, "audio/wav")},
            )
        response.raise_for_status()
        return parse_response(response.json(), audio_seconds)


def parse_response(body: dict, audio_seconds: float) -> Transcript:
    words = [
        Word(
            text=w["text"],
            start=float(w["start"]),
            end=float(w["end"]),
            confidence=math.exp(w["logprob"]) if w.get("logprob") is not None else None,
        )
        for w in body.get("words", [])
        if w.get("type") == "word"
    ]
    return Transcript(
        engine=ScribeEngine.name,
        text=body.get("text", ""),
        words=words,
        audio_seconds=audio_seconds,
        raw=body,
    )
