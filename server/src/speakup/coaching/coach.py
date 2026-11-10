"""`coach_take` and `coaching_info`."""

from __future__ import annotations

import logging
from datetime import UTC, datetime
from typing import Any, Literal, NotRequired, TypedDict

import anthropic

from . import claude
from .errors import CoachingFailed, CoachingUnavailable
from .models import CoachingOutput, output_schema
from .prompt import (
    coach_prompt,
    lexical_filler_ids,
    prompt_version,
    reask_content,
    request_language,
    rubric,
    system_prompt,
)
from .prompt import user_content as render_user_content
from .validate import add_anchor_times, validate_output

log = logging.getLogger(__name__)

AnalysisDoc = dict[str, Any]
CoachingReportDoc = dict[str, Any]

SCHEMA_VERSION = "coaching/1"


class PromptContext(TypedDict):
    kind: Literal["prepared", "impromptu"]
    text: str
    notes: str | None
    category: str | None
    target_seconds: int
    # `en` or `zh`; a request without it is English. A zh take is coached in Chinese.
    language: NotRequired[Literal["en", "zh"]]


class PreviousTake(TypedDict):
    attempt: int
    analysis: AnalysisDoc  # finalized
    coaching: CoachingReportDoc | None  # None: no focus items to judge, comparison stays null


class CoachingRequest(TypedDict):
    take_id: str
    mode: Literal["home", "driving"]  # driving may later select a faster model
    prompt: PromptContext
    attempt: int
    analysis: AnalysisDoc  # rules-only stage output of this take
    previous: PreviousTake | None  # set for a retry with a done previous take


def coaching_info() -> dict[str, Any]:
    """{"available", "model", "rubric_version", "prompt_version"} for /v1/health."""
    return {
        "available": bool(claude.api_key()),
        "model": claude.model(),
        "rubric_version": rubric().version,
        "prompt_version": coach_prompt().version,
    }


def build_request(request: CoachingRequest, extra_user: list[str] | None = None) -> dict[str, Any]:
    """The parameters `coach_take` sends for this request. Pure; used by tests and the CLI."""
    user = [render_user_content(request), *(extra_user or [])]
    return claude.request_params(
        model_id=claude.model(),
        system=system_prompt(request_language(request)),
        user=user,
        schema=output_schema(CoachingOutput),
        effort=claude.COACH_EFFORT,
        max_tokens=claude.COACH_MAX_TOKENS,
    )


def _now() -> str:
    return datetime.now(UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def _previous_focus_count(request: CoachingRequest) -> int | None:
    previous = request.get("previous")
    if previous is None or previous.get("coaching") is None:
        return None
    return len(previous["coaching"]["focus"])


def coach_take_with_usage(request: CoachingRequest) -> tuple[CoachingReportDoc, list[dict]]:
    """`coach_take`, also returning token usage per call (for the developer command)."""
    if not claude.api_key():
        raise CoachingUnavailable("ANTHROPIC_API_KEY is not set")
    api = claude.client()

    analysis = request["analysis"]
    words = analysis["words"]
    filler_ids = lexical_filler_ids(analysis)
    focus_count = _previous_focus_count(request)

    usages: list[dict] = []
    extra: list[str] = []
    errors: list[str] = []
    for attempt in (1, 2):
        params = build_request(request, extra)
        try:
            reply = claude.send(api, params)
        except anthropic.APIError as exc:
            raise CoachingFailed(f"Claude API error: {type(exc).__name__}: {exc}") from exc
        usages.append(reply.usage)

        if reply.stop_reason == "refusal":
            raise CoachingFailed("Claude declined to coach this take (stop_reason: refusal)")
        if reply.stop_reason == "max_tokens":
            errors = ["The output was cut off at the token limit; keep every field concise."]
            output = None
        else:
            output, errors = validate_output(
                reply.text,
                words=words,
                lexical_filler_ids=filler_ids,
                previous_focus_count=focus_count,
            )
        if output is not None:
            report: CoachingReportDoc = {
                "schema_version": SCHEMA_VERSION,
                "take_id": request["take_id"],
                "created_at": _now(),
                "model": reply.model,
                "rubric_version": rubric().version,
                "prompt_version": prompt_version(request_language(request)),
                **add_anchor_times(output.model_dump(mode="json"), words),
            }
            return report, usages

        log.warning(
            "coaching output for take %s failed checks (call %d): %s",
            request["take_id"],
            attempt,
            errors,
        )
        extra = [reask_content(errors, reply.text)]

    raise CoachingFailed("Coaching output failed validation twice: " + "; ".join(errors))


def coach_take(request: CoachingRequest) -> CoachingReportDoc:
    """One Claude call (plus at most one re-ask). Returns the stored form of the report."""
    report, _ = coach_take_with_usage(request)
    return report
