"""Metrics and nervousness signs of the analysis document.

See docs/architecture.md#metrics and #nervousness-signs. Event-derived metrics are a separate
function because finalization recomputes them after coaching changes the events; the acoustic
ones depend only on the audio and the words.
"""

from __future__ import annotations

import math
from statistics import median
from typing import Any

import numpy as np

from speakup.analysis.acoustics import Acoustics
from speakup.analysis.events import EventDoc, Segment, overlap
from speakup.analysis.thresholds import Thresholds
from speakup.analysis.words import WordDoc

MetricsDoc = dict[str, Any]

# Below this much measured audio a pitch or volume statistic is noise, so it is reported as null.
MIN_FRAMES = 100  # 1 second of 10 ms frames
MIN_FRAMES_PER_QUARTER = 10


def _r(value: float, digits: int = 2) -> float:
    return round(float(value), digits)


def speaking_span(words: list[WordDoc]) -> tuple[float, float]:
    spoken = [w for w in words if w["kind"] != "non_speech"]
    return spoken[0]["start"], max(w["end"] for w in spoken)


def quarters(t0: float, t1: float) -> list[Segment]:
    step = (t1 - t0) / 4
    return [(t0 + n * step, t0 + (n + 1) * step) for n in range(4)]


def word_count(words: list[WordDoc]) -> int:
    return sum(w["kind"] == "word" for w in words)


def event_metrics(
    events: list[EventDoc], words: int, speaking_s: float, *, coached: bool = False
) -> MetricsDoc:
    """The metrics that count events: fillers, blocks, pauses, restarts and repetitions."""

    def of(type_: str) -> list[EventDoc]:
        return [e for e in events if e["type"] == type_]

    filled = len(of("filled_pause"))
    candidates = of("lexical_filler")
    lexical = sum(e["is_filler"] is True for e in candidates)
    judged = coached and all(e["filler_resolution"] == "coaching" for e in candidates)
    blocks = [e["end"] - e["start"] for e in of("block")]
    boundary = [e["end"] - e["start"] for e in of("boundary_pause")]
    return {
        "fillers": {
            "filled_pauses": filled,
            "lexical": lexical,
            "lexical_candidates": len(candidates),
            "per_100_words": _r((filled + lexical) / words * 100) if words else 0.0,
            "resolution": "coaching" if judged else "rules",
        },
        "blocks": {
            "count": len(blocks),
            "per_minute": _r(len(blocks) / speaking_s * 60) if speaking_s > 0 else 0.0,
            "longest_s": _r(max(blocks, default=0.0)),
            "total_s": _r(sum(blocks)),
        },
        "boundary_pauses": {
            "count": len(boundary),
            "median_s": _r(median(boundary)) if boundary else None,
        },
        "restarts": len(of("restart")),
        "repetitions": len(of("repetition")),
    }


def _pace(
    words: list[WordDoc], track: list[Segment], span: Segment, parts: list[Segment]
) -> MetricsDoc:
    counted = [w for w in words if w["kind"] == "word"]
    voiced = overlap(track, *span)
    speaking = span[1] - span[0]

    def wpm(count: int, seconds: float) -> float:
        return _r(count / seconds * 60, 1) if seconds > 0 else 0.0

    by_quarter = []
    for n, (lo, hi) in enumerate(parts):
        last = n == len(parts) - 1
        count = sum(
            lo <= (w["start"] + w["end"]) / 2 < hi or (last and (w["start"] + w["end"]) / 2 == hi)
            for w in counted
        )
        by_quarter.append(wpm(count, overlap(track, lo, hi)))
    return {
        "wpm_voiced": wpm(len(counted), voiced),
        "wpm_speaking": wpm(len(counted), speaking),
        "by_quarter_wpm": by_quarter,
    }


def _frames_in(times: np.ndarray, segments: list[Segment]) -> np.ndarray:
    mask = np.zeros(len(times), dtype=bool)
    for lo, hi in segments:
        mask |= (times >= lo) & (times <= hi)
    return mask


def _quarter_masks(times: np.ndarray, parts: list[Segment]) -> list[np.ndarray]:
    return [(times >= lo) & (times < hi) if n < 3 else (times >= lo) & (times <= hi)
            for n, (lo, hi) in enumerate(parts)]  # fmt: skip


def _pitch(acoustics: Acoustics, span: Segment, parts: list[Segment]) -> MetricsDoc | None:
    times, hz = acoustics.pitch_times, acoustics.pitch_hz
    voiced = np.isfinite(hz) & (hz > 0) & _frames_in(times, [span])
    if voiced.sum() < MIN_FRAMES:
        return None
    center = float(np.median(hz[voiced]))
    # Drop octave jumps: frames more than an octave from the median are tracking errors far more
    # often than real speech.
    semitones = 12 * np.log2(np.where(voiced, hz, center) / center)
    voiced &= np.abs(semitones) <= 12
    masks = [voiced & q for q in _quarter_masks(times, parts)]
    if voiced.sum() < MIN_FRAMES or any(m.sum() < MIN_FRAMES_PER_QUARTER for m in masks):
        return None
    center = float(np.median(hz[voiced]))
    st = 12 * np.log2(hz[voiced] / center)
    return {
        "median_hz": _r(center, 1),
        "variation_st": _r(np.std(st)),
        "range_st": _r(np.percentile(st, 95) - np.percentile(st, 5)),
        "by_quarter_median_hz": [_r(np.median(hz[m]), 1) for m in masks],
    }


def _volume(
    acoustics: Acoustics, track: list[Segment], span: Segment, parts: list[Segment]
) -> MetricsDoc | None:
    times, db = acoustics.intensity_times, acoustics.intensity_db
    voiced = _frames_in(times, track) & _frames_in(times, [span]) & np.isfinite(db)
    masks = [voiced & q for q in _quarter_masks(times, parts)]
    if voiced.sum() < MIN_FRAMES or any(m.sum() < MIN_FRAMES_PER_QUARTER for m in masks):
        return None
    return {
        "median_db": _r(np.median(db[voiced]), 1),
        "variation_db": _r(np.std(db[voiced])),
        "by_quarter_median_db": [_r(np.median(db[m]), 1) for m in masks],
    }


def compute_metrics(
    words: list[WordDoc],
    events: list[EventDoc],
    track: list[Segment],
    acoustics: Acoustics,
) -> MetricsDoc:
    span = speaking_span(words)
    speaking = span[1] - span[0]
    parts = quarters(*span)
    count = word_count(words)
    return {
        "duration_s": _r(acoustics.duration_s),
        "speech_start_s": _r(span[0]),
        "speaking_s": _r(speaking),
        "voiced_s": _r(overlap(track, *span)),
        "word_count": count,
        **event_metrics(events, count, speaking),
        "pace": _pace(words, track, span, parts),
        "pitch": _pitch(acoustics, span, parts),
        "volume": _volume(acoustics, track, span, parts),
    }


def _clock(seconds: float) -> str:
    whole = int(seconds)
    return f"{whole // 60}:{whole % 60:02d}"


def nervousness_signs(
    words: list[WordDoc], events: list[EventDoc], metrics: MetricsDoc, thresholds: Thresholds
) -> list[dict[str, Any]]:
    signs: list[dict[str, Any]] = []
    span = speaking_span(words)
    last_quarter = quarters(*span)[3]

    if span[1] - span[0] >= thresholds.quarter_signs_min_speaking_s:
        first, last = metrics["pace"]["by_quarter_wpm"][0], metrics["pace"]["by_quarter_wpm"][3]
        if first > 0:
            change = (last - first) / first * 100
            if change >= thresholds.pace_rise_percent:
                signs.append(
                    {
                        "type": "pace_rise",
                        "start": _r(last_quarter[0]),
                        "end": _r(last_quarter[1]),
                        "value": _r(change, 1),
                        "detail": f"Pace rose {change:.0f}% from the first quarter to the last "
                        f"({first:.0f} to {last:.0f} words per minute).",
                    }
                )

    blocks = sorted((e for e in events if e["type"] == "block"), key=lambda e: e["start"])
    i = 0
    while i < len(blocks):
        j = i
        while (
            j + 1 < len(blocks)
            and blocks[j + 1]["start"] - blocks[i]["start"] <= thresholds.block_cluster_window_s
        ):
            j += 1
        count = j - i + 1
        if count >= thresholds.block_cluster_count:
            start, end = blocks[i]["start"], blocks[j]["end"]
            signs.append(
                {
                    "type": "block_cluster",
                    "start": _r(start),
                    "end": _r(end),
                    "value": count,
                    "detail": f"{count} blocks came within {math.ceil(end - start)} seconds, "
                    f"from {_clock(start)} to {_clock(end)}.",
                }
            )
            i = j + 1
        else:
            i += 1

    pitch = metrics["pitch"]
    if pitch is not None and span[1] - span[0] >= thresholds.quarter_signs_min_speaking_s:
        first, last = pitch["by_quarter_median_hz"][0], pitch["by_quarter_median_hz"][3]
        rise = 12 * math.log2(last / first)
        if rise >= thresholds.pitch_rise_st:
            signs.append(
                {
                    "type": "pitch_rise",
                    "start": _r(last_quarter[0]),
                    "end": _r(last_quarter[1]),
                    "value": _r(rise, 1),
                    "detail": f"Pitch rose {rise:.1f} semitones from the first quarter to the "
                    f"last ({first:.0f} to {last:.0f} Hz).",
                }
            )
    return sorted(signs, key=lambda s: s["start"])
