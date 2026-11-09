"""AssemblyAI Universal-3.5 Pro, pre-recorded API.

Docs: https://www.assemblyai.com/docs and https://www.assemblyai.com/llms/models.md
Universal-3.5 Pro ignores the `disfluencies` flag; verbatim output is requested with a prompt.
"""

from __future__ import annotations

import time
from pathlib import Path

import httpx

from speakup.config import setting
from speakup.stt import Transcript, Word

BASE_URL = "https://api.assemblyai.com"
VERBATIM_PROMPT = (
    "Transcribe verbatim, exactly as spoken. Keep every filler word such as um, uh, er and hmm. "
    "Keep every repeated word and every false start or cut-off word. Do not clean up the speech."
)


class AssemblyAIEngine:
    name = "assemblyai"
    description = "AssemblyAI Universal-3.5 Pro with a verbatim prompt (cloud)"
    cost_per_hour_usd = 0.26

    def __init__(self, client: httpx.Client | None = None, poll_seconds: float = 1.0) -> None:
        self._client = client
        self._poll_seconds = poll_seconds

    def missing_config(self) -> str | None:
        return None if setting("ASSEMBLYAI_API_KEY") else "set ASSEMBLYAI_API_KEY in server/.env"

    def prepare(self) -> None:
        pass

    def transcribe(self, wav_path: Path, audio_seconds: float) -> Transcript:
        client = self._client or httpx.Client(timeout=600)
        headers = {"authorization": setting("ASSEMBLYAI_API_KEY") or ""}
        upload = client.post(
            f"{BASE_URL}/v2/upload", headers=headers, content=wav_path.read_bytes()
        )
        upload.raise_for_status()
        job = client.post(
            f"{BASE_URL}/v2/transcript",
            headers=headers,
            json={
                "audio_url": upload.json()["upload_url"],
                "speech_models": ["universal-3-5-pro"],
                "language_code": "en",
                "prompt": VERBATIM_PROMPT,
            },
        )
        job.raise_for_status()
        job_id = job.json()["id"]
        while True:
            poll = client.get(f"{BASE_URL}/v2/transcript/{job_id}", headers=headers)
            poll.raise_for_status()
            body = poll.json()
            if body["status"] == "completed":
                return parse_response(body, audio_seconds)
            if body["status"] == "error":
                raise RuntimeError(f"AssemblyAI transcription failed: {body.get('error')}")
            time.sleep(self._poll_seconds)


def parse_response(body: dict, audio_seconds: float) -> Transcript:
    words = [
        Word(
            text=w["text"],
            start=w["start"] / 1000,
            end=w["end"] / 1000,
            confidence=w.get("confidence"),
        )
        for w in body.get("words") or []
    ]
    return Transcript(
        engine=AssemblyAIEngine.name,
        text=body.get("text") or "",
        words=words,
        audio_seconds=audio_seconds,
        raw=body,
    )
