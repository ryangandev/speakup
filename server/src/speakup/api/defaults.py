"""The real pieces `create_app()` builds when a caller does not pass fakes."""

from __future__ import annotations

import importlib
import logging
from typing import Any

from speakup.config import ServerSettings
from speakup.pipeline import Analyzer, Coach
from speakup.store import Store
from speakup.stt import Engine

log = logging.getLogger(__name__)

# The contract's default engine name; the registry names the CrisperWhisper sizes explicitly.
ENGINE_ALIASES = {"crisperwhisper": "crisper-large"}


def default_store(settings: ServerSettings) -> Store:
    return Store(settings.data_dir)


def default_engine(settings: ServerSettings) -> Engine:
    from speakup.stt.registry import all_engines

    engines = all_engines()
    name = ENGINE_ALIASES.get(settings.stt_engine, settings.stt_engine)
    if name not in engines:
        known = ", ".join(sorted([*engines, *ENGINE_ALIASES]))
        raise RuntimeError(
            f"SPEAKUP_STT_ENGINE={settings.stt_engine!r} is not an engine. Choose one of: {known}."
        )
    engine = engines[name]
    problem = engine.missing_config()
    if problem:
        log.warning(
            "Speech-to-text engine %s cannot run: %s. Takes will fail with stt_failed until "
            "it is fixed; reprocess them afterwards.",
            engine.name,
            problem,
        )
    return engine


def _load(module_name: str, what: str) -> Any:
    try:
        return importlib.import_module(module_name)
    except ImportError as exc:
        raise RuntimeError(
            f"The server needs {module_name} ({what}), which could not be imported: {exc}. "
            f"It is built separately; see docs/architecture.md#module-boundaries-and-ownership."
        ) from exc


def load_analyzer() -> Analyzer:
    return _load("speakup.analysis", "analysis and metrics")


def load_coach() -> Coach:
    return _load("speakup.coaching", "coaching and question generation")
