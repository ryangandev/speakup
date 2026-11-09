"""Analysis: a take's audio and verbatim transcript in, the analysis document out.

The document marks every filled pause, lexical filler candidate, repetition, restart and pause,
and carries the metrics and nervousness signs. Its shape is the contract in
docs/architecture.md#analysis-output; `finalize` applies coaching to it and `compare_metrics`
compares two takes.
"""

from __future__ import annotations

from datetime import UTC, datetime
from importlib import metadata
from pathlib import Path
from typing import Any

from speakup.analysis.acoustics import Acoustics, measure
from speakup.analysis.events import detect_events, find_pauses, voice_track
from speakup.analysis.finalize import (
    AnalysisDoc,
    CoachingReportDoc,
    MetricChange,
    compare_metrics,
    finalize,
)
from speakup.analysis.metrics import compute_metrics, nervousness_signs, word_count
from speakup.analysis.thresholds import Thresholds
from speakup.analysis.words import word_docs
from speakup.stt import Transcript

__all__ = [
    "AnalysisDoc",
    "CoachingReportDoc",
    "MetricChange",
    "NoSpeech",
    "Thresholds",
    "analyze",
    "build_analysis",
    "compare_metrics",
    "finalize",
]

SCHEMA_VERSION = "analysis/1"

# The engine names in speakup.stt.registry, with the model each runs and the package that
# reports its version. A Transcript records only the engine name.
_STT_MODELS: dict[str, tuple[str, str | None]] = {
    "crisper-large": ("nyralabs/CrisperWhisper2.0_large", "crisperwhisper"),
    "crisper-turbo": ("nyralabs/CrisperWhisper2.0_turbo", "crisperwhisper"),
    "scribe": ("scribe_v2", None),
    "assemblyai": ("universal-3-5-pro", None),
    "apple": ("SpeechTranscriber", None),
}


class NoSpeech(Exception):
    """Fewer words were transcribed than an analysis needs."""


def _version(package: str | None) -> str | None:
    if package is None:
        return None
    try:
        return metadata.version(package)
    except metadata.PackageNotFoundError:
        return None


def _provenance(transcript: Transcript, thresholds: Thresholds) -> dict[str, Any]:
    model, package = _STT_MODELS.get(transcript.engine, (None, None))
    return {
        "pipeline_version": _version("speakup-server"),
        "stt": {"engine": transcript.engine, "model": model, "version": _version(package)},
        "vad": {"engine": "silero-vad", "version": _version("silero-vad")},
        "prosody": {"engine": "parselmouth", "version": _version("praat-parselmouth")},
        "thresholds_version": thresholds.version,
    }


def build_analysis(
    *,
    take_id: str,
    transcript: Transcript,
    acoustics: Acoustics,
    thresholds: Thresholds | None = None,
) -> AnalysisDoc:
    """`analyze` with the audio already measured, so tests can pass hand-built acoustics."""
    thresholds = thresholds or Thresholds()
    words = word_docs(transcript.words)
    if word_count(words) < thresholds.min_words:
        raise NoSpeech(f"{word_count(words)} words transcribed; at least {thresholds.min_words}")

    track, _ = voice_track(words, acoustics.speech, thresholds)
    pauses = find_pauses(words, track, thresholds)
    events = detect_events(words, pauses, thresholds)
    for n, e in enumerate(events):
        e["id"] = f"e{n}"
    metrics = compute_metrics(words, events, track, acoustics)
    created = datetime.now(UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")
    return {
        "schema_version": SCHEMA_VERSION,
        "take_id": take_id,
        "created_at": created,
        "coaching_applied": False,
        "provenance": _provenance(transcript, thresholds),
        "words": words,
        "events": events,
        "metrics": metrics,
        "nervousness_signs": nervousness_signs(words, events, metrics, thresholds),
    }


def analyze(
    *,
    take_id: str,
    wav16k: Path,
    transcript: Transcript,
    thresholds: Thresholds | None = None,
) -> AnalysisDoc:
    """Rules-only analysis. Raises NoSpeech when fewer than 5 words were transcribed."""
    thresholds = thresholds or Thresholds()
    if word_count(word_docs(transcript.words)) < thresholds.min_words:
        raise NoSpeech(f"fewer than {thresholds.min_words} words transcribed")
    return build_analysis(
        take_id=take_id, transcript=transcript, acoustics=measure(wav16k), thresholds=thresholds
    )
