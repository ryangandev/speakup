"""Settings and secrets.

Secrets live in `server/.env`, which git ignores. Real environment variables win over the file.
"""

from __future__ import annotations

import os
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
