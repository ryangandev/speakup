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
from speakup.analysis.words import WordDoc, word_docs
from speakup.stt import Transcript
from speakup.text import LANGUAGES

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
    "qwen3-asr-1.7b": ("Qwen/Qwen3-ASR-1.7B", "qwen-asr"),
    "qwen3-asr-0.6b": ("Qwen/Qwen3-ASR-0.6B", "qwen-asr"),
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


def _language(language: str) -> str:
    if language not in LANGUAGES:
        raise ValueError(f"unknown language {language!r}; expected one of {LANGUAGES}")
    return language


def _spoken_words(transcript: Transcript, thresholds: Thresholds, language: str) -> list[WordDoc]:
    words = word_docs(transcript.words, language)
    count = word_count(words, language)
    if count < thresholds.min_words:
        raise NoSpeech(f"{count} words transcribed; at least {thresholds.min_words}")
    return words


def _document(
    take_id: str,
    transcript: Transcript,
    words: list[WordDoc],
    acoustics: Acoustics,
    thresholds: Thresholds,
    language: str,
) -> AnalysisDoc:
    track, _ = voice_track(words, acoustics.speech, thresholds)
    pauses = find_pauses(words, track, thresholds)
    events = detect_events(words, pauses, thresholds, language)
    for n, e in enumerate(events):
        e["id"] = f"e{n}"
    metrics = compute_metrics(words, events, track, acoustics, language)
    created = datetime.now(UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")
    return {
        "schema_version": SCHEMA_VERSION,
        "take_id": take_id,
        "language": language,
        "created_at": created,
        "coaching_applied": False,
        "provenance": _provenance(transcript, thresholds),
        "words": words,
        "events": events,
        "metrics": metrics,
        "nervousness_signs": nervousness_signs(words, events, metrics, thresholds, language),
    }


def build_analysis(
    *,
    take_id: str,
    transcript: Transcript,
    acoustics: Acoustics,
    thresholds: Thresholds | None = None,
    language: str = "en",
) -> AnalysisDoc:
    """`analyze` with the audio already measured, so tests can pass hand-built acoustics."""
    thresholds = thresholds or Thresholds()
    language = _language(language)
    words = _spoken_words(transcript, thresholds, language)
    return _document(take_id, transcript, words, acoustics, thresholds, language)


def analyze(
    *,
    take_id: str,
    wav16k: Path,
    transcript: Transcript,
    thresholds: Thresholds | None = None,
    language: str = "en",
) -> AnalysisDoc:
    """Rules-only analysis. Raises NoSpeech when fewer than 5 words (for Mandarin, characters)
    were transcribed, before the audio is read. `language` is the prompt's: `en` or `zh`."""
    thresholds = thresholds or Thresholds()
    language = _language(language)
    words = _spoken_words(transcript, thresholds, language)
    return _document(take_id, transcript, words, measure(wav16k), thresholds, language)
