"""Flush data to the disk itself, not just the operating system's cache.

On macOS `fsync` only reaches the drive's cache; `F_FULLFSYNC` asks the drive to write through.
A 201 for an upload means the recording survives a power cut, so the file and the directory
entries that name it are flushed this way.
"""

from __future__ import annotations

import fcntl
import os
from pathlib import Path


def fsync_fd(fd: int) -> None:
    full = getattr(fcntl, "F_FULLFSYNC", None)
    if full is not None:
        try:
            fcntl.fcntl(fd, full)
            return
        except OSError:
            pass  # not every filesystem supports it; fall back to a plain fsync
    os.fsync(fd)


def fsync_dir(path: Path) -> None:
    """Flush a directory so a file created or renamed in it is not lost."""
    fd = os.open(path, os.O_RDONLY)
    try:
        fsync_fd(fd)
    finally:
        os.close(fd)
