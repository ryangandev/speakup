"""Ryan's interest themes, learned by Claude from the topics he chooses himself."""

from __future__ import annotations

import logging
from typing import Any

import anthropic
from pydantic import ValidationError

from . import claude
from .models import ThemeList, output_schema
from .prompt import themes_prompt

log = logging.getLogger(__name__)

MAX_THEMES = 6
MAX_WORDS = 3
MAX_NAME_LENGTH = 40


def themes_user_content(
    *, topics: list[dict[str, str]], current: list[str], hidden: list[str]
) -> str:
    parts = ["<his_topics>", *(f"[{t['language']}] {t['text']}" for t in topics), "</his_topics>"]
    parts += ["<current_themes>", *(current or ["None yet."]), "</current_themes>"]
    if hidden:
        parts += ["<removed_themes>", *hidden, "</removed_themes>"]
    parts.append(f"Name up to {MAX_THEMES} themes.")
    return "\n".join(parts)


def build_request(
    *, topics: list[dict[str, str]], current: list[str], hidden: list[str]
) -> dict[str, Any]:
    return claude.request_params(
        model_id=claude.model(),
        system=themes_prompt().text,
        user=themes_user_content(topics=topics, current=current, hidden=hidden),
        schema=output_schema(ThemeList),
        effort=claude.THEMES_EFFORT,
        max_tokens=claude.THEMES_MAX_TOKENS,
    )


def clean_names(names: list[str], *, hidden: list[str]) -> list[str]:
    """Usable theme names: trimmed, one to three words, each once in any case, never a hidden
    one, at most six."""
    removed = {h.lower() for h in hidden}
    seen: set[str] = set()
    cleaned: list[str] = []
    for raw in names:
        name = " ".join(raw.split())
        key = name.lower()
        if not name or key in removed or key in seen:
            continue
        if len(name.split()) > MAX_WORDS or len(name) > MAX_NAME_LENGTH:
            continue
        seen.add(key)
        cleaned.append(name)
    return cleaned[:MAX_THEMES]


def learn_themes(
    *, topics: list[dict[str, str]], current: list[str], hidden: list[str]
) -> list[str] | None:
    """The themes behind Ryan's recent own topics, most prominent first, or None when there is
    no API key or the call fails. `hidden` are names he removed, never returned."""
    if not claude.api_key():
        return None
    params = build_request(topics=topics, current=current, hidden=hidden)
    try:
        api = claude.client().with_options(
            timeout=claude.THEMES_TIMEOUT_SECONDS, max_retries=claude.THEMES_MAX_RETRIES
        )
        reply = claude.send(api, params)
        parsed = ThemeList.model_validate_json(reply.text)
    except (anthropic.APIError, ValidationError) as exc:
        log.warning("theme learning failed, keeping the current themes: %s", exc)
        return None
    return clean_names(parsed.themes, hidden=hidden)
