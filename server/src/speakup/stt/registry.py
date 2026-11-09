"""The engines the bake-off can run, by name."""

from __future__ import annotations

from speakup.stt import Engine
from speakup.stt.apple import AppleEngine
from speakup.stt.assemblyai import AssemblyAIEngine
from speakup.stt.crisperwhisper import CrisperWhisperEngine
from speakup.stt.elevenlabs import ScribeEngine


def all_engines() -> dict[str, Engine]:
    engines: list[Engine] = [
        ScribeEngine(),
        CrisperWhisperEngine("large"),
        CrisperWhisperEngine("turbo"),
        AssemblyAIEngine(),
        AppleEngine(),
    ]
    return {e.name: e for e in engines}
