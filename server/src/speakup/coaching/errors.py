"""Exceptions the pipeline handles."""

from __future__ import annotations


class CoachingUnavailable(Exception):
    """No Anthropic API key is configured."""


class CoachingFailed(Exception):
    """The API call or output validation failed after retries."""
