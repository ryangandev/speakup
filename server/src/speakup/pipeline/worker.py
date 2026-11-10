"""The background worker that moves takes through the pipeline stages.

One thread processes one take at a time, oldest recording first. See
docs/architecture.md#pipeline-orchestration.
"""

from __future__ import annotations

import contextlib
import json
import logging
import threading
from collections.abc import Callable, Iterator, Mapping, Sequence
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
# A stage running longer than this gets a warning in the log (a stuck call blocks the queue).
SLOW_STAGE_SECONDS = 600.0
_START_STAGE = {"uploaded": 0, "transcribing": 0, "analyzing": 1, "coaching": 2}


# Builds the engine for a language other than English when its first take arrives. Raises with
# a plain reason when the configured engine is not registered or cannot run here.
EngineFactory = Callable[[], Engine]

LANGUAGE_NAMES = {"en": "English", "zh": "Mandarin"}


class Analyzer(Protocol):  # satisfied by the speakup.analysis module
    def analyze(
        self, *, take_id: str, wav16k: Path, transcript: Transcript, language: str = "en"
    ) -> AnalysisDoc: ...

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
    """`engine` transcribes English and is prepared when the worker starts. `engines` maps each
    other language to a factory for its engine, built and prepared on that language's first
    take; every engine stays loaded once prepared, one instance per engine name."""

    def __init__(
        self,
        store: Store,
        engine: Engine,
        analyzer: Analyzer,
        coach: Coach,
        *,
        engines: Mapping[str, EngineFactory] | None = None,
        convert: Callable[[Path, Path], Any] = to_wav16k,
        stt_retry_delays: Sequence[float] = (5.0, 30.0),
        idle_seconds: float = 30.0,
        slow_stage_seconds: float = SLOW_STAGE_SECONDS,
        startup_retry_seconds: float = 5.0,
    ) -> None:
        self.store = store
        self.engine = engine
        self._engine_factories = dict(engines or {})
        self._engines: dict[str, Engine] = {"en": engine}
        self._prepared: set[str] = set()
        self.analyzer = analyzer
        self.coach = coach
        self._convert = convert
        self._stt_retry_delays = tuple(stt_retry_delays)
        self._idle_seconds = idle_seconds
        self._slow_stage_seconds = slow_stage_seconds
        self._startup_retry_seconds = startup_retry_seconds
        self._wake = threading.Event()
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

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
        # The thread must outlive a locked database or a failing engine: health stays "ok"
        # whatever the worker does, so a dead worker would go unnoticed.
        while not self._stop.is_set():
            try:
                self._prepare_engine()
                self.resume()
                break
            except Exception:
                log.exception(
                    "The worker could not start; retrying in %ss", self._startup_retry_seconds
                )
                if self._stop.wait(self._startup_retry_seconds):
                    return
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
        self._prepared.add(self.engine.name)

    def engine_for(self, language: str) -> Engine:
        """The engine for a language, built on first use. Raises StageFailure("stt_failed")
        with the reason when there is none or it cannot be built; nothing is cached then, so a
        reprocess after fixing the setup tries again."""
        if language in self._engines:
            return self._engines[language]
        name = LANGUAGE_NAMES.get(language, language)
        factory = self._engine_factories.get(language)
        if factory is None:
            raise StageFailure("stt_failed", f"No speech-to-text engine is set up for {name}.")
        try:
            engine = factory()
        except Exception as exc:
            log.warning("The %s speech-to-text engine is not available: %s", name, exc)
            raise StageFailure(
                "stt_failed", f"The {name} speech-to-text engine is not available: {exc}"
            ) from None
        # Two languages configured with the same engine share one loaded model.
        for loaded in self._engines.values():
            if loaded.name == engine.name:
                engine = loaded
                break
        self._engines[language] = engine
        return engine

    def resume(self) -> None:
        """Count the stages a restart interrupted, so a take that keeps killing the process
        stops being retried. Only a stage the worker had in hand counts; a take that was merely
        waiting in a queue (after a reprocess, say) does not."""
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

    @contextlib.contextmanager
    def _watch(self, take_id: str, stage: str) -> Iterator[None]:
        """Warn once if the stage is still running after `slow_stage_seconds`."""

        def warn() -> None:
            log.warning(
                "Take %s has been in %s for over %d seconds; the queue is blocked behind it",
                take_id,
                stage,
                self._slow_stage_seconds,
            )

        timer = threading.Timer(self._slow_stage_seconds, warn)
        timer.daemon = True
        timer.start()
        try:
            yield
        finally:
            timer.cancel()

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
                with self._watch(take_id, "transcribing"):
                    self._stage_transcribe(take_id)
            if start <= 1:
                stage = "analyzing"
                with self._watch(take_id, "analyzing"):
                    self._stage_analyze(take_id)
            stage = "coaching"
            with self._watch(take_id, "coaching"):
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
        engine = self.engine_for(self._language(take_id))
        transcript = self._transcribe(take_id, engine, wav, seconds)
        self.store.save_transcript(take_id, transcript.engine, transcript_to_json(transcript))

    def _transcribe(self, take_id: str, engine: Engine, wav: Path, seconds: float) -> Transcript:
        delays = list(self._stt_retry_delays)
        attempt = 0
        while True:
            try:
                if engine.name not in self._prepared:
                    engine.prepare()
                    self._prepared.add(engine.name)
                return engine.transcribe(wav, seconds)
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
                language=self._language(take_id),
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
            report, usage = self._call_coach(request)
            final_doc = self.analyzer.finalize(stage_doc, report)
        except Exception as exc:
            if _named(exc, "CoachingUnavailable", self.coach):
                log.warning("Take %s: coaching is unavailable: %s", take_id, exc)
                self.store.set_coaching_status(take_id, "unavailable")
            else:
                log.warning("Take %s: coaching failed: %s", take_id, exc, exc_info=True)
                self.store.set_coaching_status(take_id, "failed")
            return
        self.store.save_coaching(take_id, take["analysis_id"], report, final_doc, usage)

    def _call_coach(self, request: dict[str, Any]) -> tuple[CoachingReportDoc, Any]:
        """The report and, when the coach reports it, the token usage of its calls."""
        with_usage = getattr(self.coach, "coach_take_with_usage", None)
        if with_usage is not None:
            report, usage = with_usage(request)
            return report, usage
        return self.coach.coach_take(request), None

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
                "language": prompt["language"],
            },
            "attempt": take["attempt"],
            "analysis": docs[0],
            "previous": previous,
        }

    def _language(self, take_id: str) -> str:
        prompt = self.store.get_prompt(self._take(take_id)["prompt_id"])
        assert prompt is not None
        return prompt["language"]

    def _take(self, take_id: str) -> dict[str, Any]:
        take = self.store.get_take(take_id)
        assert take is not None
        return take
