"""The engines the bake-off can run, by name."""

from __future__ import annotations

from speakup.stt import Engine
from speakup.stt.apple import AppleEngine
from speakup.stt.assemblyai import AssemblyAIEngine
from speakup.stt.crisperwhisper import CrisperWhisperEngine
from speakup.stt.elevenlabs import ScribeEngine
from speakup.stt.qwen import QwenASREngine


def all_engines() -> dict[str, Engine]:
    engines: list[Engine] = [
        ScribeEngine(),
        CrisperWhisperEngine("large"),
        CrisperWhisperEngine("turbo"),
        AssemblyAIEngine(),
        AppleEngine(),
        QwenASREngine("1.7B"),
        QwenASREngine("0.6B"),
    ]
    return {e.name: e for e in engines}
