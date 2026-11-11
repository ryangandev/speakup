"""The coaching output Claude returns, as Pydantic models, and its JSON Schema.

The shape is the contract in docs/architecture.md#coaching-output-what-claude-returns.
Structured outputs reject numeric bounds, string lengths and complex array constraints,
so the models carry none; counts and anchors are checked in `validate.py`.
"""

from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field

Dimension = Literal["answer_first", "layering", "focus", "concision", "fluency", "close"]
Level = Literal["strong", "okay", "needs_work"]
DIMENSIONS: tuple[str, ...] = (
    "answer_first",
    "layering",
    "focus",
    "concision",
    "fluency",
    "close",
)


class _Strict(BaseModel):
    model_config = ConfigDict(extra="forbid")


class Anchor(_Strict):
    quote: str = Field(description="The exact words, copied from the transcript in order.")
    word_start: int = Field(description="Index of the first quoted word.")
    word_end: int = Field(description="Index just after the last quoted word.")


class Strength(_Strict):
    dimension: Dimension
    point: str
    anchor: Anchor


class FocusItem(_Strict):
    dimension: Dimension
    title: str = Field(description="A short imperative, at most six words.")
    problem: str
    evidence: list[Anchor] = Field(description="One to three anchors.")
    instruction: str = Field(description="What to do differently in the very next take.")


class DimensionLevel(_Strict):
    level: Level
    evidence: str


class Dimensions(_Strict):
    answer_first: DimensionLevel
    layering: DimensionLevel
    focus: DimensionLevel
    concision: DimensionLevel
    fluency: DimensionLevel
    close: DimensionLevel


class OutlinePoint(_Strict):
    summary: str
    role: Literal["main", "support", "example", "aside", "close"]
    word_start: int
    word_end: int


class Outline(_Strict):
    main_point: str
    main_point_first: bool
    points: list[OutlinePoint]


class ReferenceVersion(_Strict):
    text: str = Field(description="Paragraphs separated by a blank line.")
    structure: str


class FillerRuling(_Strict):
    event_id: str
    is_filler: bool


class Annotation(_Strict):
    type: Literal["off_topic", "restart"]
    word_start: int
    word_end: int
    note: str


class FocusOutcome(_Strict):
    previous_focus_index: int
    outcome: Literal["improved", "partly_improved", "not_improved", "not_applicable"]
    evidence: str
    anchor: Anchor | None


class Comparison(_Strict):
    summary: str
    focus_outcomes: list[FocusOutcome]


class CoachingOutput(_Strict):
    verdict: str
    strength: Strength
    focus: list[FocusItem] = Field(description="One or two items, most important first.")
    dimensions: Dimensions
    outline: Outline
    reference_version: ReferenceVersion
    filler_rulings: list[FillerRuling]
    annotations: list[Annotation]
    comparison: Comparison | None


class Question(_Strict):
    text: str
    category: Literal["decision", "status", "explain", "pushback", "other"]
    target_seconds: int


class QuestionList(_Strict):
    questions: list[Question]


class InterestQuestion(_Strict):
    text: str
    theme: str = Field(description="The theme the question is about, as named in the request.")
    target_seconds: int


class InterestQuestionList(_Strict):
    questions: list[InterestQuestion]


class ThemeList(_Strict):
    themes: list[str] = Field(description="Up to six short theme names, most prominent first.")


def _drop_titles(node: Any) -> Any:
    """Remove the `title` keys Pydantic adds to every schema node; they only cost tokens.

    Walks schema nodes only, so a property that is itself named "title" is kept.
    """
    if isinstance(node, list):
        return [_drop_titles(item) for item in node]
    if not isinstance(node, dict):
        return node
    out: dict[str, Any] = {}
    for key, value in node.items():
        if key == "title" and isinstance(value, str):
            continue
        if key in ("properties", "$defs"):
            out[key] = {name: _drop_titles(schema) for name, schema in value.items()}
        else:
            out[key] = _drop_titles(value)
    return out


def output_schema(model: type[BaseModel]) -> dict[str, Any]:
    """The JSON Schema sent as `output_config.format.schema`."""
    return _drop_titles(model.model_json_schema())
