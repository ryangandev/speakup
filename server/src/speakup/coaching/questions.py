"""Impromptu questions, from Claude or from the built-in banks, on two tracks.

Work questions come with Ryan's work context, by category. Interest questions are on his own
themes and get harder as he practises a theme: personal and reflective first, then explaining and
giving an opinion, then taking a side and answering a counterpoint.
"""

from __future__ import annotations

import json
import logging
import random
from functools import cache
from typing import Any, TypedDict

import anthropic
from pydantic import ValidationError

from . import claude
from .models import InterestQuestionList, QuestionList, output_schema
from .prompt import RESOURCES, interests_prompt, questions_prompt

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
        {
            "text": q["text"],
            "category": q["category"],
            "theme": None,
            "target_seconds": q["target_seconds"],
        }
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


_LANGUAGE_LINES = {
    "en": "Language: English.",
    "zh": "Language: Mandarin Chinese. Write the questions in Simplified Chinese.",
}


def _language_line(language: str) -> str:
    return _LANGUAGE_LINES.get(language, _LANGUAGE_LINES["en"])


def questions_user_content(
    *, count: int, category: str | None, exclude: list[str], language: str = "en"
) -> str:
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
    parts.append(_language_line(language))
    parts.append(f"Write {count} new {noun} {wanted}.")
    return "\n".join(parts)


def build_request(
    *, count: int, category: str | None, exclude: list[str], language: str = "en"
) -> dict[str, Any]:
    return claude.request_params(
        model_id=claude.model(),
        system=questions_prompt().text,
        user=questions_user_content(
            count=count, category=category, exclude=exclude, language=language
        ),
        schema=output_schema(QuestionList),
        effort=claude.QUESTIONS_EFFORT,
        max_tokens=claude.QUESTIONS_MAX_TOKENS,
    )


def _from_claude(
    *, count: int, category: str | None, exclude: list[str], language: str
) -> list[dict] | None:
    params = build_request(count=count, category=category, exclude=exclude, language=language)
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
            {
                "text": q.text.strip(),
                "category": q.category,
                "theme": None,
                "target_seconds": seconds,
            }
        )
    if len(questions) < count:
        log.warning(
            "Claude returned %d usable questions of %d; using the bank", len(questions), count
        )
        return None
    return questions[:count]


# -- interests ----------------------------------------------------------------------------------


class InterestContext(TypedDict):
    """What the server knows for interest questions."""

    theme: str | None  # the requested theme; None means any of Ryan's themes
    takes: int  # his takes on interest prompts of that theme (of every theme for None)
    themes: list[str]  # his visible themes, pinned first
    topics: list[dict[str, str]]  # his recent own topics, newest first: {"text", "language"}


INTEREST_CATEGORY = "interest"
LEVEL_SECONDS = {1: 60, 2: 90, 3: 120}
_INTEREST_MIN_SECONDS, _INTEREST_MAX_SECONDS = 60, 120


def level_for(takes: int) -> int:
    """1 below three takes on a theme, 2 from three to seven, 3 from eight."""
    if takes < 3:
        return 1
    return 2 if takes < 8 else 3


def level_mix(level: int, count: int) -> list[int]:
    """The level of each question: mostly `level`, with every third one from the level below,
    so a harder theme still has an easier question now and then."""
    return [level - 1 if level > 1 and i % 3 == 2 else level for i in range(count)]


@cache
def interest_bank() -> dict[str, Any]:
    return json.loads((RESOURCES / "interest-bank.json").read_text(encoding="utf-8"))


def general_themes() -> list[str]:
    """Themes for interest questions before Ryan has any of his own."""
    return [t["en"] for t in interest_bank()["general_themes"]]


def _theme_in(theme: str, language: str) -> str:
    """A theme's name inside a question: a general theme has a Chinese name for zh."""
    if language == "zh":
        for general in interest_bank()["general_themes"]:
            if general["en"].lower() == theme.lower():
                return general["zh"]
    return theme


def _bank_language(language: str) -> str:
    return language if language in interest_bank()["templates"] else "en"


def from_interest_bank(
    *,
    count: int,
    context: InterestContext,
    language: str,
    exclude: list[str],
    rng: random.Random | None = None,
) -> list[dict[str, Any]]:
    """Up to `count` questions from templates, never an excluded one. Any theme spreads the
    questions across Ryan's themes, or the general ones while he has none."""
    rng = rng or random
    templates = interest_bank()["templates"][_bank_language(language)]
    pool = [context["theme"]] if context["theme"] else (context["themes"] or general_themes())
    used = {_key(t) for t in exclude}
    used_themes: set[str] = set()
    questions: list[dict[str, Any]] = []
    for level in level_mix(level_for(context["takes"]), count):
        candidates = [
            (template.format(theme=_theme_in(theme, language)), theme)
            for template in templates[str(level)]
            for theme in pool
        ]
        candidates = [(text, theme) for text, theme in candidates if _key(text) not in used]
        fresh = [c for c in candidates if c[1] not in used_themes]
        if not candidates:
            continue
        text, theme = rng.choice(fresh or candidates)
        used.add(_key(text))
        used_themes.add(theme)
        questions.append(
            {
                "text": text,
                "category": INTEREST_CATEGORY,
                "theme": theme,
                "target_seconds": LEVEL_SECONDS[level],
            }
        )
    return questions


def interests_user_content(
    *, count: int, context: InterestContext, language: str, exclude: list[str]
) -> str:
    levels = level_mix(level_for(context["takes"]), count)
    themes = context["themes"]
    parts = ["<themes>", *(themes or ["None yet."]), "</themes>"]
    if not themes and not context["theme"]:
        parts.append("Until he has themes, use these general ones: " + ", ".join(general_themes()))
    parts.append("<his_topics>")
    parts += [f"[{t['language']}] {t['text']}" for t in context["topics"]] or ["None yet."]
    parts.append("</his_topics>")
    if exclude:
        parts += ["<avoid>", *exclude, "</avoid>"]
    if context["theme"]:
        parts.append(f"Theme: {context['theme']}")
    else:
        parts.append("Theme: any of his themes; give each question the theme it is about.")
    parts.append(_language_line(language))
    noun = "question" if count == 1 else "questions"
    parts.append(
        f"Write {count} new {noun}, at these levels in order: {', '.join(map(str, levels))}."
    )
    return "\n".join(parts)


def build_interests_request(
    *, count: int, context: InterestContext, language: str, exclude: list[str]
) -> dict[str, Any]:
    return claude.request_params(
        model_id=claude.model(),
        system=interests_prompt().text,
        user=interests_user_content(
            count=count, context=context, language=language, exclude=exclude
        ),
        schema=output_schema(InterestQuestionList),
        effort=claude.QUESTIONS_EFFORT,
        max_tokens=claude.QUESTIONS_MAX_TOKENS,
    )


def _interests_from_claude(
    *, count: int, context: InterestContext, language: str, exclude: list[str]
) -> list[dict] | None:
    params = build_interests_request(
        count=count, context=context, language=language, exclude=exclude
    )
    try:
        reply = claude.send(claude.client(), params)
        parsed = InterestQuestionList.model_validate_json(reply.text)
    except (anthropic.APIError, ValidationError) as exc:
        log.warning("interest question generation failed, using the bank: %s", exc)
        return None

    known = {t.lower(): t for t in (context["themes"] or general_themes())}
    excluded = {_key(t) for t in exclude}
    seen: set[str] = set()
    questions: list[dict[str, Any]] = []
    for q in parsed.questions:
        key = _key(q.text)
        if not key or key in excluded or key in seen:
            continue
        seen.add(key)
        if context["theme"]:
            theme: str | None = context["theme"]
        else:
            named = q.theme.strip()
            theme = known.get(named.lower(), named) or None
        seconds = min(max(q.target_seconds, _INTEREST_MIN_SECONDS), _INTEREST_MAX_SECONDS)
        questions.append(
            {
                "text": q.text.strip(),
                "category": INTEREST_CATEGORY,
                "theme": theme,
                "target_seconds": seconds,
            }
        )
    if len(questions) < count:
        log.warning(
            "Claude returned %d usable interest questions of %d; using the bank",
            len(questions),
            count,
        )
        return None
    return questions[:count]


# -- both tracks ---------------------------------------------------------------------------------


def generate_questions(
    *,
    count: int,
    category: str | None,
    exclude: list[str],
    track: str = "work",
    language: str = "en",
    interests: InterestContext | None = None,
) -> dict[str, Any]:
    """{"source": "claude" | "bank", "questions": [...]}. Never raises for a missing key.

    `track` is "work" (by `category`) or "interests" (by `interests`, which the server fills
    from its store). Claude writes in `language`; the work bank is English only.
    """
    if track == "interests":
        context = interests or InterestContext(theme=None, takes=0, themes=[], topics=[])
        if claude.api_key():
            questions = _interests_from_claude(
                count=count, context=context, language=language, exclude=exclude
            )
            if questions is not None:
                return {"source": "claude", "questions": questions}
        return {
            "source": "bank",
            "questions": from_interest_bank(
                count=count, context=context, language=language, exclude=exclude
            ),
        }

    if claude.api_key():
        questions = _from_claude(count=count, category=category, exclude=exclude, language=language)
        if questions is not None:
            return {"source": "claude", "questions": questions}
    return {
        "source": "bank",
        "questions": from_bank(count=count, category=category, exclude=exclude),
    }
