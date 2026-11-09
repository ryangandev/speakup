"""Settings, the Anthropic client, and the request parameters for each call."""

from __future__ import annotations

import logging
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import anthropic

from speakup.config import data_dir as server_data_dir
from speakup.config import setting

log = logging.getLogger(__name__)

DEFAULT_MODEL = "claude-opus-5-5"
REQUEST_TIMEOUT_SECONDS = 120.0

# Coaching is the product's core value, so it runs above Claude Opus 5.5's default
# effort (medium). Questions are short and run at the default.
COACH_EFFORT = "high"
QUESTIONS_EFFORT = "medium"
COACH_MAX_TOKENS = 16000
QUESTIONS_MAX_TOKENS = 4000

# Server-side refusal fallback: if a safety classifier declines a request (for example,
# work content that mentions security tooling), the API reruns it on Anthropic's
# recommended fallback model instead of returning a refusal. Only these models take it.
FALLBACK_BETA = "server-side-fallback-2026-07-01"
_FALLBACK_MODELS = {"claude-opus-5-5", "claude-opus-5", "claude-fable-5-1", "claude-sonnet-5-5"}


def api_key() -> str | None:
    return setting("ANTHROPIC_API_KEY")


def model() -> str:
    return setting("SPEAKUP_COACH_MODEL", DEFAULT_MODEL) or DEFAULT_MODEL


def data_dir() -> Path:
    """The server's data directory; the default lives in `speakup.config`."""
    return server_data_dir()


_clients: dict[str, Any] = {}


def client() -> Any:
    """The Anthropic client for the configured key. Raises LookupError without a key."""
    key = api_key()
    if not key:
        raise LookupError("ANTHROPIC_API_KEY is not set")
    if key not in _clients:
        _clients.clear()
        # The SDK retries 429, 5xx and connection errors itself. The timeout keeps one stuck
        # call from blocking the worker's queue.
        _clients[key] = anthropic.Anthropic(
            api_key=key, max_retries=2, timeout=REQUEST_TIMEOUT_SECONDS
        )
    return _clients[key]


@dataclass
class Reply:
    """The parts of a response the coaching module uses."""

    text: str
    model: str
    stop_reason: str | None
    usage: dict[str, Any]


def request_params(
    *,
    model_id: str,
    system: str,
    user: str | list[str],
    schema: dict[str, Any],
    effort: str,
    max_tokens: int,
) -> dict[str, Any]:
    """Keyword arguments for `client.beta.messages.create`.

    The system prompt is cached: a retry usually follows within minutes, and the
    prompt plus schema is the stable prefix of every coaching request.
    """
    blocks = [user] if isinstance(user, str) else user
    params: dict[str, Any] = {
        "model": model_id,
        "max_tokens": max_tokens,
        "system": [{"type": "text", "text": system, "cache_control": {"type": "ephemeral"}}],
        "messages": [
            {"role": "user", "content": [{"type": "text", "text": b} for b in blocks]},
        ],
        "thinking": {"type": "adaptive"},
        "output_config": {
            "effort": effort,
            "format": {"type": "json_schema", "schema": schema},
        },
    }
    if model_id in _FALLBACK_MODELS:
        params["betas"] = [FALLBACK_BETA]
        params["fallbacks"] = "default"
    return params


def send(api: Any, params: dict[str, Any]) -> Reply:
    """Make one call. Raises anthropic.APIError subclasses on API failure."""
    response = api.beta.messages.create(**params)
    text = "".join(block.text for block in response.content if block.type == "text")
    usage = response.usage
    usage_info = {
        "input_tokens": getattr(usage, "input_tokens", None),
        "output_tokens": getattr(usage, "output_tokens", None),
        "cache_read_input_tokens": getattr(usage, "cache_read_input_tokens", None),
        "cache_creation_input_tokens": getattr(usage, "cache_creation_input_tokens", None),
    }
    log.info(
        "claude %s stop=%s request_id=%s usage=%s",
        response.model,
        response.stop_reason,
        getattr(response, "_request_id", None),
        usage_info,
    )
    return Reply(
        text=text,
        model=response.model or params["model"],
        stop_reason=response.stop_reason,
        usage=usage_info,
    )
