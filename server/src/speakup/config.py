"""Settings and secrets.

Secrets live in `server/.env`, which git ignores. Real environment variables win over the file.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

SERVER_DIR = Path(__file__).resolve().parents[2]
REPO_DIR = SERVER_DIR.parent
ENV_FILE = SERVER_DIR / ".env"


def _read_env_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        values[key.strip()] = value.strip().strip("'\"")
    return values


_FILE_VALUES = _read_env_file(ENV_FILE)


def setting(name: str, default: str | None = None) -> str | None:
    """Return a setting from the environment, then `server/.env`, then the default."""
    value = os.environ.get(name) or _FILE_VALUES.get(name)
    return value if value else default


# -- Server settings (M1): see docs/architecture.md#configuration ----------------------------

DEFAULT_PORT = 8765
DEFAULT_STT_ENGINE = "crisperwhisper"
DEFAULT_COACH_MODEL = "claude-opus-5-5"


@dataclass(frozen=True)
class ServerSettings:
    api_token: str | None
    data_dir: Path
    stt_engine: str
    coach_model: str
    port: int


def data_dir() -> Path:
    """Where the server keeps its database, audio and profile.md (`SPEAKUP_DATA_DIR`).

    A relative path is relative to the repository.
    """
    path = Path(setting("SPEAKUP_DATA_DIR", "data/server") or "data/server").expanduser()
    return path if path.is_absolute() else REPO_DIR / path


def server_settings() -> ServerSettings:
    """Read the server settings. A relative `SPEAKUP_DATA_DIR` is relative to the repository."""
    raw_port = setting("SPEAKUP_PORT", str(DEFAULT_PORT)) or str(DEFAULT_PORT)
    try:
        port = int(raw_port)
    except ValueError:
        raise ValueError(f"SPEAKUP_PORT must be a number, not {raw_port!r}") from None
    if not 1 <= port <= 65535:
        raise ValueError(f"SPEAKUP_PORT must be between 1 and 65535, not {port}")
    return ServerSettings(
        api_token=setting("SPEAKUP_API_TOKEN"),
        data_dir=data_dir(),
        stt_engine=setting("SPEAKUP_STT_ENGINE", DEFAULT_STT_ENGINE) or DEFAULT_STT_ENGINE,
        coach_model=setting("SPEAKUP_COACH_MODEL", DEFAULT_COACH_MODEL) or DEFAULT_COACH_MODEL,
        port=port,
    )
