"""The numbers that turn measurements into events and signs, versioned as one value.

Sources are in docs/research.md#practice-methods; every value is a starting point to be
calibrated on Ryan's recordings. Change `version` whenever a value changes, so analyses made
with different thresholds are never compared as if they were the same.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Thresholds:
    version: str = "thresholds/0"

    # A transcript with fewer words than this is treated as no speech.
    min_words: int = 5

    # Silent pauses: 250 ms is the best-supported threshold for fluency measures
    # (de Jong and Bosker 2013).
    min_pause_s: float = 0.25
    # Cross-check: the engine's own word gap must show at least this much room for a pause the
    # voice-activity track reports, so a pause is only marked when both sources agree.
    pause_min_word_gap_s: float = 0.1
    # When voice activity covers less than this share of the transcribed word time, the track
    # is not trusted (whispering, heavy noise) and pauses and voiced time come from word times.
    vad_min_word_coverage: float = 0.5

    # Restarts: how many words back a repair may reach to find where the abandoned start began.
    restart_lookback_words: int = 3
    # Abandoned phrases ("we need to - we should"): the longest abandoned start, in words.
    abandoned_phrase_max_words: int = 4

    # Nervousness signs (docs/architecture.md#nervousness-signs).
    quarter_signs_min_speaking_s: float = 20.0
    pace_rise_percent: float = 15.0
    block_cluster_count: int = 3
    block_cluster_window_s: float = 15.0
    pitch_rise_st: float = 2.0
