"""Fakes and fixtures for the API and pipeline tests.

The JSON examples in docs/architecture.md are the canonical fixtures: they are read from the doc
at test time, so a change to the contract that the server does not follow fails a test.
"""

from __future__ import annotations

import copy
import hashlib
import io
import json
import shutil
import wave
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from fastapi.testclient import TestClient

from speakup.api import create_app
from speakup.pipeline import Worker
from speakup.store import Store
from speakup.stt import Transcript, Word

TOKEN = "test-token-not-a-secret-0123456789abcdef"
DOC = Path(__file__).resolve().parents[2] / "docs" / "architecture.md"

SESSION_ID = "0b6f3c1e-8f5a-4f3e-9a51-2d1c7e4b9a10"
PROMPT_ID = "7d2e9a44-1c3b-4e8f-b6a2-93f0c5d1e7a8"
TAKE1_ID = "c41a7e02-5b9d-4c66-8e1f-0a7b3d92f5c4"
TAKE2_ID = "e98b1f37-2a4c-4d1e-9f60-6b5c8a0d3e21"


# -- the doc's examples ---------------------------------------------------------------------


def doc_blocks(heading: str) -> list[Any]:
    """The parsed ```json blocks under the heading line `heading`, up to the next heading of the
    same or a higher level."""
    lines = DOC.read_text().splitlines()
    start = next(i for i, line in enumerate(lines) if line == heading)
    level = len(heading) - len(heading.lstrip("#"))
    blocks: list[Any] = []
    current: list[str] | None = None
    indent = 0
    for line in lines[start + 1 :]:
        stripped = line.strip()
        if current is None:
            if stripped == "```json":
                current = []
                indent = len(line) - len(line.lstrip())
            elif line.startswith("#") and len(line) - len(line.lstrip("#")) <= level:
                break
        elif stripped == "```":
            blocks.append(json.loads("\n".join(current)))
            current = None
        else:
            current.append(line[indent:])
    return blocks


def example(heading: str, index: int = 0) -> Any:
    return copy.deepcopy(doc_blocks(heading)[index])


ANALYSIS_EXAMPLE = example("### Analysis example")
COACHING_EXAMPLE = example("### Coaching example", 0)
COACHING_COMPARISON_EXAMPLE = example("### Coaching example", 1)
COMPARISON_EXAMPLE = example("### Comparison")
HEALTH_EXAMPLE = example("#### `GET /v1/health`")
QUESTIONS_EXAMPLE = example("#### `POST /v1/questions`", 1)
SESSION_REQUEST = example("#### `PUT /v1/sessions/{session_id}`", 0)
SESSION_RESOURCE = example("#### `PUT /v1/sessions/{session_id}`", 1)
SESSION_PATCH = example("#### `PATCH /v1/sessions/{session_id}`", 0)
SESSIONS_LIST = example("#### `GET /v1/sessions?before=<timestamp>&limit=<n>`")
SESSION_DETAIL = example("#### `GET /v1/sessions/{session_id}`")
PROMPT_REQUEST = example("#### `PUT /v1/prompts/{prompt_id}`")
TAKE_METADATA = example("#### `PUT /v1/takes/{take_id}`", 0)
TAKE_UPLOADED = example("#### `PUT /v1/takes/{take_id}`", 1)
TAKE_DONE = example("#### `GET /v1/takes/{take_id}`")
REPORT_SKETCH = example("#### `GET /v1/takes/{take_id}/report`")


# -- audio ----------------------------------------------------------------------------------


def wav_bytes(seconds: float = 1.0, rate: int = 16_000, tone: int = 0) -> bytes:
    """A mono 16-bit PCM WAV of silence; `tone` makes different files hash differently."""
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(rate)
        out.writeframes(b"\x00\x00" * int(seconds * rate) + tone.to_bytes(2, "little") * 2)
    return buffer.getvalue()


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def copy_convert(src: Path, dst: Path) -> Path:
    """Stands in for ffmpeg/afconvert: the test WAVs already are valid."""
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(src, dst)
    return dst


# -- fakes ----------------------------------------------------------------------------------


class FakeClock:
    def __init__(self, value: str = "2026-11-09T08:00:00.000Z") -> None:
        self.value = value

    def __call__(self) -> str:
        return self.value

    def set(self, value: str) -> None:
        self.value = value


class FakeEngine:
    """Returns a fixed transcript; `words` sets how long it is."""

    name = "crisperwhisper"
    description = "fake"
    cost_per_hour_usd = 0.0

    def __init__(self, store: Store | None = None) -> None:
        self.store = store
        self.words = 20
        self.errors: list[BaseException] = []  # raised one per call before succeeding
        self.calls: list[tuple[Path, float]] = []
        self.prepared = 0
        self.statuses: list[str] = []

    def missing_config(self) -> str | None:
        return None

    def prepare(self) -> None:
        self.prepared += 1

    def transcribe(self, wav_path: Path, audio_seconds: float) -> Transcript:
        self.calls.append((wav_path, audio_seconds))
        if self.store is not None:
            self.statuses.append(self.store.get_take(wav_path.parent.name)["status"])
        if self.errors:
            raise self.errors.pop(0)
        words = [
            Word(text=f"w{i}", start=i * 0.3, end=i * 0.3 + 0.2, confidence=0.9)
            for i in range(self.words)
        ]
        return Transcript(
            engine=self.name,
            text=" ".join(w.text for w in words),
            words=words,
            audio_seconds=audio_seconds,
            elapsed_seconds=0.5,
        )


class NoSpeech(Exception):
    pass


class FakeAnalyzer:
    """Returns the doc's analysis example, with the take's id."""

    NoSpeech = NoSpeech

    def __init__(self, store: Store | None = None) -> None:
        self.store = store
        self.error: Exception | None = None
        self.statuses: list[str] = []
        self.analyze_calls: list[dict[str, Any]] = []

    def analyze(
        self, *, take_id: str, wav16k: Path, transcript: Transcript, language: str = "en"
    ) -> dict[str, Any]:
        self.analyze_calls.append(
            {"take_id": take_id, "wav16k": wav16k, "transcript": transcript, "language": language}
        )
        if self.store is not None:
            self.statuses.append(self.store.get_take(take_id)["status"])
        if self.error is not None:
            raise self.error
        if len(transcript.words) < 5:
            raise NoSpeech
        doc = copy.deepcopy(ANALYSIS_EXAMPLE)
        doc["take_id"] = take_id
        doc["coaching_applied"] = False
        doc["events"] = [e for e in doc["events"] if e["source"] == "rules"]
        return doc

    def finalize(self, analysis: dict[str, Any], coaching: dict[str, Any] | None) -> dict[str, Any]:
        if coaching is None:
            return copy.deepcopy(analysis)
        doc = copy.deepcopy(ANALYSIS_EXAMPLE)
        doc["take_id"] = analysis["take_id"]
        if analysis["take_id"] == TAKE2_ID:
            doc["metrics"]["fillers"]["per_100_words"] = 2.9
            doc["metrics"]["blocks"]["count"] = 1
            doc["metrics"]["restarts"] = 2
            doc["metrics"]["pace"]["wpm_voiced"] = 171.4
        return doc

    def compare_metrics(
        self, previous: dict[str, Any], current: dict[str, Any]
    ) -> list[dict[str, Any]]:
        return copy.deepcopy(COMPARISON_EXAMPLE["metric_changes"])


class CoachingUnavailable(Exception):
    pass


class CoachingFailed(Exception):
    pass


class FakeCoach:
    """Returns the doc's coaching example (attempt 1) or the retry's variation (attempt 2)."""

    CoachingUnavailable = CoachingUnavailable
    CoachingFailed = CoachingFailed

    def __init__(self, store: Store | None = None) -> None:
        self.store = store
        self.available = True
        self.error: Exception | None = None
        self.requests: list[dict[str, Any]] = []
        self.statuses: list[str] = []
        self.question_calls: list[dict[str, Any]] = []
        self.theme_calls: list[dict[str, Any]] = []
        # What learn_themes returns: names, None (no key or a failed call), or an exception.
        self.learned: list[str] | None | Exception = None

    def coaching_info(self) -> dict[str, Any]:
        info = copy.deepcopy(HEALTH_EXAMPLE["coaching"])
        info["available"] = self.available
        return info

    def coach_take(self, request: dict[str, Any]) -> dict[str, Any]:
        self.requests.append(copy.deepcopy(request))
        if self.store is not None:
            self.statuses.append(self.store.get_take(request["take_id"])["status"])
        if self.error is not None:
            raise self.error
        report = copy.deepcopy(COACHING_EXAMPLE)
        report["take_id"] = request["take_id"]
        if request["attempt"] > 1:
            report["verdict"] = (
                "Much clearer: the decision comes first and the reasons are numbered. "
                "The ending still fades out."
            )
            report["focus"] = [
                {
                    "dimension": "close",
                    "title": "Close on purpose",
                    "problem": "The answer fades out.",
                    "evidence": [
                        {
                            "quote": "so yeah",
                            "word_start": 203,
                            "word_end": 205,
                            "start": 70.1,
                            "end": 71.0,
                        }
                    ],
                    "instruction": "End on the trade-off, then stop.",
                }
            ]
            levels = {"layering": "strong", "focus": "strong"}
            for name, level in levels.items():
                report["dimensions"][name]["level"] = level
            report["comparison"] = copy.deepcopy(COACHING_COMPARISON_EXAMPLE)
        return report

    def coach_take_with_usage(self, request: dict[str, Any]) -> tuple[dict[str, Any], list[dict]]:
        report = self.coach_take(request)
        return report, [{"input_tokens": 1200, "output_tokens": 800}]

    def generate_questions(self, **kwargs: Any) -> dict[str, Any]:
        self.question_calls.append(copy.deepcopy(kwargs))
        return copy.deepcopy(QUESTIONS_EXAMPLE)

    def learn_themes(
        self, *, topics: list[dict[str, str]], current: list[str], hidden: list[str]
    ) -> list[str] | None:
        self.theme_calls.append({"topics": topics, "current": current, "hidden": hidden})
        if isinstance(self.learned, Exception):
            raise self.learned
        return copy.deepcopy(self.learned)


# -- the assembled server -------------------------------------------------------------------


@dataclass
class Env:
    store: Store
    worker: Worker
    engine: FakeEngine
    analyzer: FakeAnalyzer
    coach: FakeCoach
    clock: FakeClock
    client: TestClient
    data_dir: Path
    ids: dict[str, str] = field(default_factory=dict)

    def put_session(self, session_id: str = SESSION_ID, **body: Any):
        payload = {**SESSION_REQUEST, **body}
        return self.client.put(f"/v1/sessions/{session_id}", json=payload)

    def put_prompt(self, prompt_id: str = PROMPT_ID, **body: Any):
        payload = {**PROMPT_REQUEST, **body}
        return self.client.put(f"/v1/prompts/{prompt_id}", json=payload)

    def seed(self) -> None:
        """The session and prompt the doc's examples describe."""
        self.clock.set(SESSION_RESOURCE["created_at"])
        assert self.put_session().status_code == 201
        self.clock.set("2026-11-09T08:12:40.880Z")
        assert self.put_prompt().status_code == 201

    def upload(
        self,
        take_id: str,
        *,
        audio: bytes | None = None,
        sha: str | None = None,
        metadata_filename: str | None = None,
        **metadata: Any,
    ):
        audio = audio if audio is not None else wav_bytes(tone=int(take_id[:2], 16))
        meta = {
            **TAKE_METADATA,
            "audio_sha256": sha or sha256(audio),
            **metadata,
        }
        return self.client.put(
            f"/v1/takes/{take_id}",
            files={
                "metadata": (metadata_filename, json.dumps(meta), "application/json"),
                "audio": ("take.wav", audio, "audio/wav"),
            },
        )

    def upload_story_takes(self) -> None:
        """Attempt 1 (recorded first) and attempt 2, as in the doc."""
        self.clock.set(TAKE_UPLOADED["created_at"])
        first = self.upload(
            TAKE1_ID,
            attempt=1,
            recorded_at="2026-11-09T08:15:01.000Z",
            duration_s=96.4,
        )
        assert first.status_code == 201, first.text
        second = self.upload(TAKE2_ID)
        assert second.status_code == 201, second.text

    def take(self, take_id: str) -> dict[str, Any]:
        response = self.client.get(f"/v1/takes/{take_id}")
        assert response.status_code == 200, response.text
        return response.json()

    def run(self) -> int:
        return self.worker.run_pending()


def build_env(
    data_dir: Path,
    *,
    clock: FakeClock | None = None,
    raise_server_exceptions: bool = True,
    convert: Any = copy_convert,
    engines: dict[str, Any] | None = None,
) -> Env:
    clock = clock or FakeClock()
    store = Store(data_dir, clock=clock)
    engine = FakeEngine(store)
    analyzer = FakeAnalyzer(store)
    coach = FakeCoach(store)
    worker = Worker(
        store,
        engine,
        analyzer,
        coach,
        engines=engines,
        convert=convert,
        stt_retry_delays=(0.0, 0.0),
    )
    app = create_app(store=store, worker=worker, coach=coach, analyzer=analyzer, token=TOKEN)
    client = TestClient(
        app,
        headers={"Authorization": f"Bearer {TOKEN}"},
        raise_server_exceptions=raise_server_exceptions,
    )
    return Env(store, worker, engine, analyzer, coach, clock, client, data_dir)
