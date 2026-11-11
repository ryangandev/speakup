"""Interest questions over the API, prompt themes, and the theme endpoints with learning."""

from __future__ import annotations

from typing import Any

import pytest
from support import PROMPT_REQUEST, SESSION_ID, Env, doc_blocks, example

from speakup.api.routes import THEME_RETRY_AFTER

THEME_LIST = example("#### `GET /v1/themes`")
THEME_CREATE = example("#### `POST /v1/themes`", 0)
THEME_PATCH = example("#### `PATCH /v1/themes/{theme_id}`")
INTEREST_REQUEST = doc_blocks("#### `POST /v1/questions`")[2]


def error_of(response: Any, status: int) -> dict[str, Any]:
    assert response.status_code == status, response.text
    return response.json()["error"]


def _typed(env: Env, prompt_id: str, text: str, language: str = "en") -> None:
    body = {
        "kind": "prepared",
        "text": text,
        "notes": None,
        "category": None,
        "target_seconds": 120,
        "question_source": "typed",
        "language": language,
    }
    assert env.put_prompt(prompt_id, **body).status_code == 201


def _interest(env: Env, prompt_id: str, theme: str | None, text: str = "What is joy?") -> None:
    body = {"text": text, "category": "interest", "theme": theme, "target_seconds": 60}
    response = env.put_prompt(prompt_id, **body)
    assert response.status_code == 201, response.text


def _themes(env: Env) -> list[dict[str, Any]]:
    response = env.client.get("/v1/themes")
    assert response.status_code == 200, response.text
    return response.json()["themes"]


def _names(env: Env) -> list[str]:
    return [t["name"] for t in _themes(env)]


# -- questions ---------------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("body", "field"),
    [
        ({"track": "interests", "category": "decision"}, "category"),
        ({"track": "work", "theme": "Travel"}, "theme"),
        ({"theme": "Travel"}, "theme"),  # the default track is work
        ({"track": "interests", "theme": "   "}, "theme"),
        ({"track": "interests", "theme": "x" * 41}, "theme"),
        ({"track": "hobbies"}, "track"),
        ({"language": "fr"}, "language"),
    ],
)
def test_bad_question_requests_are_validation_failures(env: Env, body, field) -> None:
    error = error_of(env.client.post("/v1/questions", json=body), 422)
    assert error["code"] == "validation_failed"
    assert error["details"]["errors"][0]["field"] == field


def test_the_interest_example_request_is_valid(env: Env) -> None:
    assert env.client.post("/v1/questions", json=INTEREST_REQUEST).status_code == 200
    call = env.coach.question_calls[0]
    assert call["track"] == "interests"
    assert call["language"] == "zh"
    assert call["category"] is None


def test_interest_questions_get_his_themes_topics_and_takes(env: Env) -> None:
    env.seed()
    env.client.post("/v1/themes", json={"name": "Travel"})
    env.client.post("/v1/themes", json={"name": "Happiness"})
    _typed(env, "10000000-0000-4000-8000-000000000001", "Purpose of travel")
    _typed(env, "10000000-0000-4000-8000-000000000002", "被讨厌的勇气", "zh")
    travel = "10000000-0000-4000-8000-000000000003"
    _interest(env, travel, "Travel")
    _interest(env, "10000000-0000-4000-8000-000000000004", "Happiness", text="Joy?")
    for index, take_id in enumerate(
        ["20000000-0000-4000-8000-000000000001", "21000000-0000-4000-8000-000000000002"]
    ):
        response = env.upload(take_id, prompt_id=travel, attempt=index + 1)
        assert response.status_code == 201, response.text

    response = env.client.post(
        "/v1/questions",
        json={"track": "interests", "theme": "travel", "language": "zh", "exclude": ["Old?"]},
    )

    assert response.status_code == 200
    call = env.coach.question_calls[0]
    assert call["track"] == "interests"
    assert call["language"] == "zh"
    assert call["interests"] == {
        "theme": "Travel",  # his spelling
        "takes": 2,
        "themes": ["Travel", "Happiness"],
        "topics": [
            {"text": "被讨厌的勇气", "language": "zh"},
            {"text": "Purpose of travel", "language": "en"},
        ],
    }
    assert call["exclude"][0] == "Old?"
    assert "What is joy?" in call["exclude"]

    env.client.post("/v1/questions", json={"track": "interests"})
    assert env.coach.question_calls[1]["interests"]["theme"] is None
    assert env.coach.question_calls[1]["interests"]["takes"] == 2


# -- prompts -----------------------------------------------------------------------------------


def test_an_interest_prompt_keeps_its_theme(env: Env) -> None:
    env.seed()
    prompt_id = "30000000-0000-4000-8000-000000000001"
    _interest(env, prompt_id, " Happiness ")
    prompt = env.client.get(f"/v1/prompts/{prompt_id}").json()
    assert prompt["category"] == "interest"
    assert prompt["theme"] == "Happiness"
    session = env.client.get(f"/v1/sessions/{SESSION_ID}").json()
    assert session["prompts"][1]["theme"] == "Happiness"
    # An identical repeat is fine; another theme for the same id is a conflict.
    body = {"category": "interest", "target_seconds": 60, "text": "What is joy?"}
    assert env.put_prompt(prompt_id, theme="Happiness", **body).status_code == 200
    assert env.put_prompt(prompt_id, theme="Travel", **body).status_code == 409


@pytest.mark.parametrize(
    "override",
    [
        {"theme": "Travel"},  # a decision question
        {"category": None, "theme": "Travel"},
        {"category": "interest", "theme": ""},
    ],
)
def test_a_theme_needs_an_interest_prompt(env: Env, override) -> None:
    env.seed()
    response = env.put_prompt("30000000-0000-4000-8000-000000000002", **override)
    assert error_of(response, 422)["details"]["errors"][0]["field"] == "theme"


def test_a_prompt_without_a_theme_has_a_null_theme(env: Env) -> None:
    env.seed()
    # App builds from before interests send no theme.
    body = {k: v for k, v in PROMPT_REQUEST.items() if k != "theme"}
    response = env.client.put("/v1/prompts/30000000-0000-4000-8000-000000000003", json=body)
    assert response.status_code == 201
    assert response.json()["theme"] is None


# -- theme endpoints ---------------------------------------------------------------------------


def test_add_pin_and_remove_themes(env: Env) -> None:
    assert _themes(env) == []
    created = env.client.post("/v1/themes", json=THEME_CREATE)
    assert created.status_code == 201
    courage = created.json()
    assert courage["name"] == THEME_CREATE["name"]
    assert courage["source"] == "added"
    assert courage["pinned"] is False
    assert set(courage) == set(THEME_LIST["themes"][0])

    again = env.client.post("/v1/themes", json={"name": "  courage "})
    assert again.status_code == 200
    assert again.json() == courage

    travel = env.client.post("/v1/themes", json={"name": "Travel"}).json()
    assert _names(env) == ["Courage", "Travel"]
    pinned = env.client.patch(f"/v1/themes/{travel['id']}", json=THEME_PATCH)
    assert pinned.status_code == 200
    assert pinned.json() == {**travel, "pinned": True}
    assert _names(env) == ["Travel", "Courage"]

    removed = env.client.delete(f"/v1/themes/{courage['id'].upper()}")
    assert removed.status_code == 204
    assert removed.content == b""
    assert _names(env) == ["Travel"]
    assert error_of(env.client.delete(f"/v1/themes/{courage['id']}"), 404)["code"] == "not_found"


def test_bad_theme_requests(env: Env) -> None:
    assert error_of(env.client.post("/v1/themes", json={"name": " "}), 422)
    assert error_of(env.client.post("/v1/themes", json={}), 422)
    theme = env.client.post("/v1/themes", json={"name": "Travel"}).json()
    response = env.client.patch(f"/v1/themes/{theme['id']}", json={"pinned": "yes"})
    assert error_of(response, 422)["details"]["errors"][0]["field"] == "pinned"
    unknown = "40000000-0000-4000-8000-000000000001"
    assert error_of(env.client.patch(f"/v1/themes/{unknown}", json={"pinned": True}), 404)
    assert error_of(env.client.delete(f"/v1/themes/{unknown}"), 404)


# -- learning ----------------------------------------------------------------------------------


def test_themes_are_learned_from_new_typed_topics_only(env: Env) -> None:
    env.seed()
    # No typed topic yet: nothing to learn from.
    assert _themes(env) == []
    assert env.coach.theme_calls == []

    env.clock.set("2026-11-10T09:00:00.000Z")
    _typed(env, "50000000-0000-4000-8000-000000000001", "What is happiness")
    _typed(env, "50000000-0000-4000-8000-000000000002", "个人魅力是什么", "zh")
    env.coach.learned = ["Happiness", "Charisma"]
    themes = _themes(env)
    assert [(t["name"], t["source"], t["pinned"]) for t in themes] == [
        ("Happiness", "learned", False),
        ("Charisma", "learned", False),
    ]
    assert env.coach.theme_calls == [
        {
            "topics": [
                {"text": "个人魅力是什么", "language": "zh"},
                {"text": "What is happiness", "language": "en"},
            ],
            "current": [],
            "hidden": [],
        }
    ]
    # Nothing new: no second call, and the ids stay.
    assert _themes(env) == themes
    assert len(env.coach.theme_calls) == 1


def test_relearning_keeps_pinned_added_and_removed_themes(env: Env) -> None:
    env.seed()
    _typed(env, "50000000-0000-4000-8000-000000000003", "What is happiness")
    env.coach.learned = ["Happiness", "Charisma", "Stand-ups"]
    themes = {t["name"]: t for t in _themes(env)}
    env.client.patch(f"/v1/themes/{themes['Charisma']['id']}", json={"pinned": True})
    env.client.delete(f"/v1/themes/{themes['Stand-ups']['id']}")
    env.client.post("/v1/themes", json={"name": "Courage"})

    env.clock.set("2026-11-10T10:00:00.000Z")
    _typed(env, "50000000-0000-4000-8000-000000000004", "Purpose of travel")
    env.coach.learned = ["Travel", "Stand-ups", "Happiness"]
    after = _themes(env)

    assert [(t["name"], t["source"], t["pinned"]) for t in after] == [
        ("Charisma", "learned", True),
        ("Courage", "added", False),
        ("Happiness", "learned", False),
        ("Travel", "learned", False),
    ]
    happiness = next(t for t in after if t["name"] == "Happiness")
    assert happiness["id"] == themes["Happiness"]["id"]
    call = env.coach.theme_calls[-1]
    assert call["current"] == ["Charisma", "Courage", "Happiness"]
    assert call["hidden"] == ["Stand-ups"]

    # Adding a removed learned theme brings it back as his own.
    back = env.client.post("/v1/themes", json={"name": "stand-ups"})
    assert back.status_code == 200
    assert back.json()["source"] == "added"
    assert back.json()["id"] == themes["Stand-ups"]["id"]


def test_a_failed_learning_keeps_the_themes_and_waits_before_trying_again(env: Env) -> None:
    env.seed()
    env.client.post("/v1/themes", json={"name": "Courage"})
    env.clock.set("2026-11-10T09:00:00.000Z")
    _typed(env, "50000000-0000-4000-8000-000000000005", "What is happiness")
    env.coach.learned = None
    assert _names(env) == ["Courage"]
    assert len(env.coach.theme_calls) == 1

    env.coach.learned = RuntimeError("boom")
    env.clock.set("2026-11-10T09:10:00.000Z")
    assert _names(env) == ["Courage"]
    assert len(env.coach.theme_calls) == 1  # still waiting

    minutes = int(THEME_RETRY_AFTER.total_seconds() // 60)
    env.clock.set(f"2026-11-10T09:{minutes:02d}:00.000Z")
    assert _names(env) == ["Courage"]  # an exception is a failure too
    assert len(env.coach.theme_calls) == 2

    env.coach.learned = ["Happiness"]
    env.clock.set("2026-11-10T10:00:00.000Z")
    assert _names(env) == ["Courage", "Happiness"]


def test_no_learning_without_coaching(env: Env) -> None:
    env.seed()
    _typed(env, "50000000-0000-4000-8000-000000000006", "What is happiness")
    env.coach.available = False
    env.coach.learned = ["Happiness"]
    assert _themes(env) == []
    assert env.coach.theme_calls == []
    # Once the key is there, the same topics are learned.
    env.coach.available = True
    assert _names(env) == ["Happiness"]
