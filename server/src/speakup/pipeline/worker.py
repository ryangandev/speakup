"""The background worker that moves takes through the pipeline stages.

One thread processes one take at a time, oldest recording first. See
docs/architecture.md#pipeline-orchestration.
"""

from __future__ import annotations

import json
import logging
import threading
from collections.abc import Callable, Sequence
from dataclasses import asdict
from pathlib import Path
from typing import Any, Protocol

import httpx

from speakup.audio import duration_seconds, to_wav16k
from speakup.store import Store
from speakup.stt import Engine, Transcript, Word

log = logging.getLogger(__name__)

AnalysisDoc = dict[str, Any]
CoachingReportDoc = dict[str, Any]
MetricChange = dict[str, Any]

# A stage that was interrupted this many times (the process died while running it) is not
# retried again: it is probably what kills the process.
MAX_STAGE_INTERRUPTIONS = 3
_START_STAGE = {"uploaded": 0, "transcribing": 0, "analyzing": 1, "coaching": 2}


class Analyzer(Protocol):  # satisfied by the speakup.analysis module
    def analyze(self, *, take_id: str, wav16k: Path, transcript: Transcript) -> AnalysisDoc: ...

    def finalize(
        self, analysis: AnalysisDoc, coaching: CoachingReportDoc | None
    ) -> AnalysisDoc: ...

    def compare_metrics(
        self, previous: AnalysisDoc, current: AnalysisDoc
    ) -> list[MetricChange]: ...


class Coach(Protocol):  # satisfied by the speakup.coaching module
    def coaching_info(self) -> dict[str, Any]: ...

    def coach_take(self, request: dict[str, Any]) -> CoachingReportDoc: ...

    def generate_questions(
        self, *, count: int, category: str | None, exclude: list[str]
    ) -> dict[str, Any]: ...


class StageFailure(Exception):
    """A stage failed in a way that fails the take."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


class _Stopped(Exception):
    """The worker was asked to stop while a stage was waiting."""


_STAGE_FAILURE_FALLBACK = {
    "transcribing": ("stt_failed", "Speech to text failed."),
    "analyzing": ("analysis_failed", "Analysis failed."),
}


def _named(exc: BaseException, name: str, owner: object) -> bool:
    """Whether `exc` is the owner's exception called `name`.

    The analysis and coaching modules define their own exception classes; the worker
    recognises them by the owner's attribute or by class name, so it never imports them.
    """
    cls = getattr(owner, name, None)
    if isinstance(cls, type) and isinstance(exc, cls):
        return True
    return any(base.__name__ == name for base in type(exc).__mro__)


def _retryable(exc: BaseException) -> bool:
    """Network errors and 5xx answers from a cloud engine."""
    if isinstance(exc, httpx.HTTPStatusError):
        return exc.response.status_code >= 500
    return isinstance(exc, httpx.TransportError)


def transcript_to_json(transcript: Transcript) -> str:
    """The Transcript in the form `Transcript.save` writes."""
    return json.dumps(asdict(transcript), ensure_ascii=False)


def transcript_from_json(text: str) -> Transcript:
    data = json.loads(text)
    data["words"] = [Word(**w) for w in data["words"]]
    return Transcript(**data)


class Worker:
    def __init__(
        self,
        store: Store,
        engine: Engine,
        analyzer: Analyzer,
        coach: Coach,
        *,
        convert: Callable[[Path, Path], Any] = to_wav16k,
        stt_retry_delays: Sequence[float] = (5.0, 30.0),
        idle_seconds: float = 30.0,
    ) -> None:
        self.store = store
        self.engine = engine
        self.analyzer = analyzer
        self.coach = coach
        self._convert = convert
        self._stt_retry_delays = tuple(stt_retry_delays)
        self._idle_seconds = idle_seconds
        self._wake = threading.Event()
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._engine_ready = False

    # -- lifecycle ------------------------------------------------------------------------

    def start(self) -> None:
        """Start the thread: prepare the engine, resume unfinished takes, then wait for work."""
        if self._thread is not None:
            return
        self._stop.clear()
        self._thread = threading.Thread(target=self._run, name="speakup-worker", daemon=True)
        self._thread.start()

    def wake(self) -> None:
        self._wake.set()

    def stop(self, timeout: float = 5.0) -> None:
        self._stop.set()
        self._wake.set()
        if self._thread is not None:
            self._thread.join(timeout)
            self._thread = None

    def _run(self) -> None:
        self._prepare_engine()
        self.resume()
        while not self._stop.is_set():
            self._wake.clear()
            try:
                if self.process_next():
                    continue
            except _Stopped:
                break
            except Exception:
                log.exception("The worker could not read or update the database")
                self._stop.wait(5)
                continue
            self._wake.wait(self._idle_seconds)

    def _prepare_engine(self) -> None:
        try:
            self.engine.prepare()
        except Exception:
            log.exception("Speech-to-text engine %s could not prepare", self.engine.name)
            return
        self._engine_ready = True

    def resume(self) -> None:
        """A take found mid-stage at startup was interrupted by a restart; count it so a take
        that keeps killing the process stops being retried."""
        for take in self.store.interrupted_takes():
            count = self.store.bump_stage_failures(take["id"])
            log.warning(
                "Take %s was interrupted while %s (interruption %d)",
                take["id"],
                take["status"],
                count,
            )
            if count >= MAX_STAGE_INTERRUPTIONS:
                self._give_up(take)

    def _give_up(self, take: dict[str, Any]) -> None:
        if take["status"] == "coaching":
            self.store.set_coaching_status(take["id"], "failed")
            self.store.complete_take(take["id"])
            return
        code, message = _STAGE_FAILURE_FALLBACK[take["status"]]
        self.store.fail_take(take["id"], code, message)

    # -- processing -----------------------------------------------------------------------

    def run_pending(self) -> int:
        """Process every unfinished take in the calling thread; return how many were run."""
        count = 0
        while self.process_next():
            count += 1
        return count

    def process_next(self) -> bool:
        take = self.store.next_unfinished()
        if take is None:
            return False
        self._process(take)
        return True

    def _process(self, take: dict[str, Any]) -> None:
        take_id = take["id"]
        start = _START_STAGE[take["status"]]
        # Outputs a later stage needs must exist; if they do not, begin earlier.
        if start == 2 and take["analysis_id"] is None:
            start = 1
        if start == 1 and take["transcript_id"] is None:
            start = 0
        stage = "transcribing" if start == 0 else "analyzing" if start == 1 else "coaching"
        try:
            if start <= 0:
                self._stage_transcribe(take_id)
            if start <= 1:
                stage = "analyzing"
                self._stage_analyze(take_id)
            stage = "coaching"
            self._stage_coach(take_id)
            self.store.complete_take(take_id)
        except _Stopped:
            raise
        except StageFailure as failure:
            log.warning("Take %s failed: %s %s", take_id, failure.code, failure.message)
            self.store.fail_take(take_id, failure.code, failure.message)
        except Exception:
            log.exception("Take %s hit an unexpected error while %s", take_id, stage)
            if stage == "coaching":
                self.store.set_coaching_status(take_id, "failed")
                self.store.complete_take(take_id)
            else:
                code, message = _STAGE_FAILURE_FALLBACK[stage]
                self.store.fail_take(take_id, code, message)

    # Stage 1 ---------------------------------------------------------------------------

    def _stage_transcribe(self, take_id: str) -> None:
        self.store.begin_stage(take_id, "transcribing")
        wav = self.store.audio16k_path(take_id)
        try:
            self._convert(self.store.original_path(take_id), wav)
            seconds = duration_seconds(wav)
            if seconds <= 0:
                raise ValueError("the audio is empty")
        except Exception:
            log.exception("Take %s: audio conversion failed", take_id)
            raise StageFailure(
                "audio_invalid", "The audio could not be decoded or converted."
            ) from None
        transcript = self._transcribe(take_id, wav, seconds)
        self.store.save_transcript(take_id, transcript.engine, transcript_to_json(transcript))

    def _transcribe(self, take_id: str, wav: Path, seconds: float) -> Transcript:
        delays = list(self._stt_retry_delays)
        attempt = 0
        while True:
            try:
                if not self._engine_ready:
                    self.engine.prepare()
                    self._engine_ready = True
                return self.engine.transcribe(wav, seconds)
            except Exception as exc:
                if attempt < len(delays) and _retryable(exc):
                    log.warning(
                        "Take %s: speech to text failed (%s); retrying in %ss",
                        take_id,
                        exc,
                        delays[attempt],
                    )
                    if self._stop.wait(delays[attempt]):
                        raise _Stopped from exc
                    attempt += 1
                    continue
                log.exception("Take %s: speech to text failed", take_id)
                raise StageFailure("stt_failed", "Speech to text failed.") from None

    # Stages 2 and 3 ------------------------------------------------------------------

    def _stage_analyze(self, take_id: str) -> None:
        self.store.begin_stage(take_id, "analyzing")
        take = self._take(take_id)
        transcript_json = self.store.transcript_json(take["transcript_id"])
        assert transcript_json is not None  # _process starts earlier when it is missing
        try:
            stage_doc = self.analyzer.analyze(
                take_id=take_id,
                wav16k=self.store.audio16k_path(take_id),
                transcript=transcript_from_json(transcript_json),
            )
            final_doc = self.analyzer.finalize(stage_doc, None)
        except Exception as exc:
            if _named(exc, "NoSpeech", self.analyzer):
                raise StageFailure("no_speech", "Fewer than 5 words were transcribed.") from None
            log.exception("Take %s: analysis failed", take_id)
            raise StageFailure("analysis_failed", "Analysis failed.") from None
        self.store.save_analysis(take_id, take["transcript_id"], stage_doc, final_doc)

    # Stage 4 ---------------------------------------------------------------------------

    def _stage_coach(self, take_id: str) -> None:
        take = self._take(take_id)
        docs = self.store.analysis_docs(take["analysis_id"])
        assert docs is not None
        stage_doc, _ = docs
        # Rerunning coaching starts from the rules-only document.
        self.store.set_final_analysis(take["analysis_id"], self.analyzer.finalize(stage_doc, None))
        self.store.set_coaching_status(take_id, "pending")
        try:
            available = bool(self.coach.coaching_info().get("available"))
        except Exception:
            log.exception("Take %s: could not ask the coach whether it is available", take_id)
            available = False
        if not available:
            self.store.resolve_previous_take(take_id)
            self.store.set_coaching_status(take_id, "unavailable")
            return
        self.store.begin_stage(take_id, "coaching")
        try:
            request = self._coaching_request(take_id)
            report = self.coach.coach_take(request)
            final_doc = self.analyzer.finalize(stage_doc, report)
        except Exception as exc:
            if _named(exc, "CoachingUnavailable", self.coach):
                log.warning("Take %s: coaching is unavailable: %s", take_id, exc)
                self.store.set_coaching_status(take_id, "unavailable")
            else:
                log.warning("Take %s: coaching failed: %s", take_id, exc, exc_info=True)
                self.store.set_coaching_status(take_id, "failed")
            return
        self.store.save_coaching(take_id, take["analysis_id"], report, final_doc)

    def _coaching_request(self, take_id: str) -> dict[str, Any]:
        take = self._take(take_id)
        prompt = self.store.get_prompt(take["prompt_id"])
        session = self.store.get_session(take["session_id"])
        assert prompt is not None and session is not None
        docs = self.store.analysis_docs(take["analysis_id"])
        assert docs is not None
        previous_take = self.store.resolve_previous_take(take_id)
        previous = None
        if previous_take is not None:
            previous_docs = self.store.analysis_docs(previous_take["analysis_id"])
            if previous_docs is not None:
                previous = {
                    "attempt": previous_take["attempt"],
                    "analysis": previous_docs[1],
                    "coaching": self.store.coaching_doc(previous_take["coaching_id"]),
                }
        return {
            "take_id": take_id,
            "mode": session["mode"],
            "prompt": {
                "kind": prompt["kind"],
                "text": prompt["text"],
                "notes": prompt["notes"],
                "category": prompt["category"],
                "target_seconds": prompt["target_seconds"],
            },
            "attempt": take["attempt"],
            "analysis": docs[0],
            "previous": previous,
        }

    def _take(self, take_id: str) -> dict[str, Any]:
        take = self.store.get_take(take_id)
        assert take is not None
        return take
