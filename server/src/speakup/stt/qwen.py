"""Qwen3-ASR with Qwen3-ForcedAligner, run locally, for Mandarin takes.

Docs: https://github.com/QwenLM/Qwen3-ASR
Apache-2.0 code and weights. The ASR model writes punctuated, verbatim text (it keeps 嗯, 呃, 那个,
就是 and repeated characters); the forced aligner then times each Han character and each
Latin-script word, which is what pauses and blocks are measured from. It runs on the GPU (MPS).

Words come out one per aligned unit: a Han character ("我"), or a Latin-script word ("Postgres"),
with no spaces added. Punctuation from the text is attached to the unit before it ("嗯，",
"推进。"), the way the English engines attach it ("Um,").
"""

from __future__ import annotations

import importlib.util
import warnings
from collections.abc import Sequence
from pathlib import Path
from typing import Any

from speakup.config import setting
from speakup.stt import Transcript, Word

ALIGNER_REPO = "Qwen/Qwen3-ForcedAligner-0.6B"
# Qwen3-ASR's name for Mandarin. Forcing it keeps a short take from being misread as another
# language; English terms inside Chinese speech still come out in Latin script.
LANGUAGE = "Chinese"
# Hyphen-like marks that join two Latin-script units into one word ("A-P-I").
_JOINERS = set("-‐‑")


class QwenASREngine:
    cost_per_hour_usd = 0.0

    def __init__(self, size: str) -> None:
        self.size = size
        self.name = f"qwen3-asr-{size.lower()}"
        self.description = f"Qwen3-ASR {size} with Qwen3-ForcedAligner (local, Mandarin)"
        self._model: Any = None

    def missing_config(self) -> str | None:
        # find_spec, not an import: importing qwen-asr loads transformers and its tokenizers.
        if importlib.util.find_spec("qwen_asr") is None:
            return "install it with: uv sync --extra qwen"
        return None

    def prepare(self) -> None:
        if self._model is not None:
            return
        import torch
        from transformers.utils import logging as transformers_logging

        # qwen-asr imports Japanese and Korean tokenizers whose sources trigger SyntaxWarnings on
        # Python 3.12, and transformers warns about generation flags on every call; neither is
        # actionable from here.
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", SyntaxWarning)
            from qwen_asr import Qwen3ASRModel
        transformers_logging.set_verbosity_error()

        device = setting("SPEAKUP_QWEN_ASR_DEVICE", "mps")
        dtype = torch.bfloat16 if device != "cpu" else torch.float32
        self._model = Qwen3ASRModel.from_pretrained(
            f"Qwen/Qwen3-ASR-{self.size}",
            dtype=dtype,
            device_map=device,
            forced_aligner=ALIGNER_REPO,
            forced_aligner_kwargs={"dtype": dtype, "device_map": device},
        )

    def transcribe(self, wav_path: Path, audio_seconds: float) -> Transcript:
        self.prepare()
        result = self._model.transcribe(
            audio=str(wav_path), language=LANGUAGE, return_time_stamps=True
        )[0]
        items = [(i.text, float(i.start_time), float(i.end_time)) for i in result.time_stamps or []]
        return parse_output(self.name, result.text, items, audio_seconds)


def parse_output(
    engine: str, text: str, items: Sequence[tuple[str, float, float]], audio_seconds: float
) -> Transcript:
    """Turn the ASR text and the aligner's (unit, start, end) items into Words."""
    return Transcript(
        engine=engine,
        text=text,
        words=words_from_alignment(text, items),
        audio_seconds=audio_seconds,
        raw={"text": text, "items": [list(item) for item in items]},
    )


def words_from_alignment(text: str, items: Sequence[tuple[str, float, float]]) -> list[Word]:
    """One Word per aligned unit, with the punctuation that follows it in `text` attached.

    The aligner drops punctuation and splits Latin-script text at anything but letters, digits and
    apostrophes, so each unit is found in `text` in order and the marks right after it are
    attached to it. Units joined by a hyphen with no space ("A-P-I") become one Word spanning
    their times. A unit that cannot be found in `text` keeps its bare form.
    """
    positions: list[int] = []
    cursor = 0
    for unit, _, _ in items:
        found = text.find(unit, cursor)
        positions.append(found)
        if found >= 0:
            cursor = found + len(unit)

    words: list[Word] = []
    first = next((p for p in positions if p >= 0), 0)
    prefix = _marks(text[:first])
    join_previous = False
    for index, (unit, start, end) in enumerate(items):
        marks = ""
        if positions[index] >= 0:
            marks = _marks(text[positions[index] + len(unit) :])
        following = items[index + 1][0] if index + 1 < len(items) else ""
        joins_next = (
            marks != ""
            and set(marks) <= _JOINERS
            and index + 1 < len(items)
            and positions[index + 1] == positions[index] + len(unit) + len(marks)
            and _is_latin(unit)
            and _is_latin(following)
        )
        if join_previous:
            previous = words.pop()
            unit, start = previous.text + unit, previous.start
        words.append(Word(text=prefix + unit + marks.strip(), start=start, end=end))
        prefix = ""
        join_previous = joins_next
    return words


def _marks(rest: str) -> str:
    """The punctuation and spaces at the start of `rest`, up to the next letter or digit."""
    length = 0
    while length < len(rest) and not rest[length].isalnum():
        length += 1
    return rest[:length]


def _is_latin(unit: str) -> bool:
    return unit.isascii() and unit[:1].isalnum()
