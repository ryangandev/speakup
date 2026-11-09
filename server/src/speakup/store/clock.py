"""Timestamps: RFC 3339 in UTC with milliseconds, as the API contract requires."""

from __future__ import annotations

from datetime import UTC, datetime


def format_ts(moment: datetime) -> str:
    moment = moment.astimezone(UTC)
    return moment.strftime("%Y-%m-%dT%H:%M:%S.") + f"{moment.microsecond // 1000:03d}Z"


def now_ts() -> str:
    return format_ts(datetime.now(UTC))


def normalize_ts(value: str) -> str:
    """Parse an RFC 3339 timestamp with or without milliseconds and write it in the stored form.

    Raises ValueError for text that is not a timestamp or has no time zone.
    """
    moment = datetime.fromisoformat(value)
    if moment.tzinfo is None:
        raise ValueError("timestamp needs a time zone, such as Z")
    return format_ts(moment)
