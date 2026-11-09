"""Coaching: Claude calls, the coaching prompt and rubric, output validation, questions.

The contract is docs/architecture.md: "Coaching report", "Impromptu questions" and
"Module boundaries and ownership".
"""

from .coach import (
    CoachingRequest,
    PreviousTake,
    PromptContext,
    coach_take,
    coaching_info,
)
from .errors import CoachingFailed, CoachingUnavailable
from .questions import generate_questions

__all__ = [
    "CoachingFailed",
    "CoachingRequest",
    "CoachingUnavailable",
    "PreviousTake",
    "PromptContext",
    "coach_take",
    "coaching_info",
    "generate_questions",
]
