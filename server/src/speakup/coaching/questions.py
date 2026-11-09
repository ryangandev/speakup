"""Impromptu questions: from Claude with Ryan's work context, or from the built-in bank."""

from __future__ import annotations

import json
import logging
import random
from functools import cache
from typing import Any

import anthropic
from pydantic import ValidationError

from . import claude
from .models import QuestionList, output_schema
from .prompt import RESOURCES, questions_prompt

log = logging.getLogger(__name__)

CATEGORIES = ("decision", "status", "explain", "pushback", "other")
_MIN_SECONDS, _MAX_SECONDS = 30, 300


@cache
def bank() -> tuple[dict[str, Any], ...]:
    data = json.loads((RESOURCES / "question-bank.json").read_text(encoding="utf-8"))
    return tuple(data["questions"])


def _key(text: str) -> str:
    return " ".join(text.lower().split())


def from_bank(
    *, count: int, category: str | None, exclude: list[str], rng: random.Random | None = None
) -> list[dict[str, Any]]:
    """Up to `count` bank questions in `category` (any when None), never an excluded one.

    Returns fewer than `count` when the bank has no more unused questions in the category.
    """
    excluded = {_key(t) for t in exclude}
    pool = [
        {"text": q["text"], "category": q["category"], "target_seconds": q["target_seconds"]}
        for q in bank()
        if (category is None or q["category"] == category) and _key(q["text"]) not in excluded
    ]
    return (rng or random).sample(pool, min(count, len(pool)))


def profile() -> str | None:
    path = claude.data_dir() / "profile.md"
    try:
        text = path.read_text(encoding="utf-8").strip()
    except OSError:
        return None
    return text or None


def questions_user_content(*, count: int, category: str | None, exclude: list[str]) -> str:
    context = profile()
    parts = [
        "<work_context>",
        context if context else "Not given. Write general software engineering questions.",
        "</work_context>",
    ]
    if exclude:
        parts += ["<avoid>", *exclude, "</avoid>"]
    wanted = f"in the {category} category" if category else "spread across the categories"
    noun = "question" if count == 1 else "questions"
    parts.append(f"Write {count} new {noun} {wanted}.")
    return "\n".join(parts)


def build_request(*, count: int, category: str | None, exclude: list[str]) -> dict[str, Any]:
    return claude.request_params(
        model_id=claude.model(),
        system=questions_prompt().text,
        user=questions_user_content(count=count, category=category, exclude=exclude),
        schema=output_schema(QuestionList),
        effort=claude.QUESTIONS_EFFORT,
        max_tokens=claude.QUESTIONS_MAX_TOKENS,
    )


def _from_claude(*, count: int, category: str | None, exclude: list[str]) -> list[dict] | None:
    params = build_request(count=count, category=category, exclude=exclude)
    try:
        reply = claude.send(claude.client(), params)
        parsed = QuestionList.model_validate_json(reply.text)
    except (anthropic.APIError, ValidationError) as exc:
        log.warning("question generation failed, using the bank: %s", exc)
        return None

    excluded = {_key(t) for t in exclude}
    seen: set[str] = set()
    questions: list[dict[str, Any]] = []
    for q in parsed.questions:
        key = _key(q.text)
        if not key or key in excluded or key in seen:
            continue
        if category is not None and q.category != category:
            continue
        seen.add(key)
        seconds = min(max(q.target_seconds, _MIN_SECONDS), _MAX_SECONDS)
        questions.append(
            {"text": q.text.strip(), "category": q.category, "target_seconds": seconds}
        )
    if len(questions) < count:
        log.warning(
            "Claude returned %d usable questions of %d; using the bank", len(questions), count
        )
        return None
    return questions[:count]


def generate_questions(*, count: int, category: str | None, exclude: list[str]) -> dict[str, Any]:
    """{"source": "claude" | "bank", "questions": [...]}. Never raises for a missing key."""
    if claude.api_key():
        questions = _from_claude(count=count, category=category, exclude=exclude)
        if questions is not None:
            return {"source": "claude", "questions": questions}
    return {
        "source": "bank",
        "questions": from_bank(count=count, category=category, exclude=exclude),
    }
