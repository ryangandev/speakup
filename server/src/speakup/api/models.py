"""Request bodies. Unknown keys are ignored (forward compatibility); known keys are validated."""

from __future__ import annotations

import re
import uuid
from typing import Annotated, Literal

from pydantic import AfterValidator, BaseModel, Field, StrictInt, ValidationInfo
from pydantic import field_validator as validator

from speakup.store import normalize_ts


def parse_id(value: str) -> str:
    """A UUID in canonical lowercase form."""
    try:
        return str(uuid.UUID(value))
    except ValueError:
        raise ValueError("must be a UUID") from None


def _timestamp(value: str) -> str:
    try:
        return normalize_ts(value)
    except ValueError:
        raise ValueError("must be an RFC 3339 timestamp with a time zone") from None


Uuid = Annotated[str, AfterValidator(parse_id)]
Timestamp = Annotated[str, AfterValidator(_timestamp)]
Rating = Annotated[StrictInt, Field(ge=1, le=5)]

Category = Literal["decision", "status", "explain", "pushback", "other"]


class SessionCreate(BaseModel):
    mode: Literal["home", "driving"]
    started_at: Timestamp
    nervousness_before: Rating | None = None


class SessionPatch(BaseModel):
    ended_at: Timestamp | None = None
    nervousness_before: Rating | None = None
    nervousness_after: Rating | None = None


class QuestionsRequest(BaseModel):
    count: Annotated[StrictInt, Field(ge=1, le=10)] = 3
    category: Category | None = None
    exclude: list[str] = Field(default_factory=list)


class PromptCreate(BaseModel):
    session_id: Uuid
    kind: Literal["prepared", "impromptu"]
    text: str
    notes: str | None = None
    category: Category | None = None
    target_seconds: Annotated[StrictInt, Field(ge=15, le=900)]
    question_source: Literal["typed", "claude", "bank"]

    @validator("text")
    @classmethod
    def _text_not_blank(cls, value: str) -> str:
        if not value.strip():
            raise ValueError("must not be empty")
        return value

    @validator("notes")
    @classmethod
    def _notes_prepared_only(cls, value: str | None, info: ValidationInfo) -> str | None:
        if value is not None and info.data.get("kind") == "impromptu":
            raise ValueError("must be null for an impromptu prompt")
        return value

    @validator("category")
    @classmethod
    def _category_impromptu_only(cls, value: str | None, info: ValidationInfo) -> str | None:
        if value is not None and info.data.get("kind") == "prepared":
            raise ValueError("must be null for a prepared prompt")
        return value


_SHA256 = re.compile(r"^[0-9a-fA-F]{64}$")


class TakeMetadata(BaseModel):
    prompt_id: Uuid
    attempt: Annotated[StrictInt, Field(ge=1)]
    recorded_at: Timestamp
    duration_s: Annotated[float, Field(ge=0, strict=True)]
    audio_sha256: str
    # The iOS input port type. Any string is accepted so a new route never rejects an upload.
    mic_route: str | None = None

    @validator("audio_sha256")
    @classmethod
    def _sha256(cls, value: str) -> str:
        if not _SHA256.match(value):
            raise ValueError("must be 64 hexadecimal characters")
        return value.lower()


class ReprocessRequest(BaseModel):
    from_stage: Literal["transcribing", "analyzing", "coaching"]
