"""Every endpoint under /v1. See docs/architecture.md#server-api."""

from __future__ import annotations

import hashlib
import json
import logging
import os
import tempfile
from datetime import datetime, timedelta
from importlib import metadata
from pathlib import Path
from typing import Annotated, Any

from fastapi import APIRouter, Depends, Query, Request, Response
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import FileResponse
from pydantic import ValidationError
from starlette.datastructures import UploadFile

from speakup.api import resources
from speakup.api.errors import (
    ApiError,
    not_found,
    unknown_parent,
    validation_details,
    validation_error,
)
from speakup.api.models import (
    PromptCreate,
    QuestionsRequest,
    ReprocessRequest,
    SessionCreate,
    SessionPatch,
    TakeMetadata,
    ThemeCreate,
    ThemePatch,
    parse_id,
)
from speakup.pipeline import Analyzer, Coach, Worker
from speakup.store import Conflict, InvalidState, Store, normalize_ts
from speakup.store.durable import fsync_fd

MAX_AUDIO_BYTES = 100 * 1024 * 1024
# Multipart framing and the metadata part on top of the audio.
MULTIPART_OVERHEAD = 1024 * 1024
RECENT_QUESTIONS = 50
# Ryan's own topics that interest questions and theme learning read.
TOPICS_FOR_QUESTIONS = 20
TOPICS_FOR_THEMES = 40
# After a failed theme learning, GET /v1/themes waits this long before calling Claude again.
THEME_RETRY_AFTER = timedelta(minutes=15)
NO_UPPER_BOUND = "9999-12-31T23:59:59.999Z"

router = APIRouter(prefix="/v1")
log = logging.getLogger(__name__)


def _server_version() -> str:
    try:
        return metadata.version("speakup-server")
    except metadata.PackageNotFoundError:
        return "0.0.0"


async def _store(request: Request) -> Store:
    return request.app.state.store


async def _worker(request: Request) -> Worker:
    return request.app.state.worker


async def _coach(request: Request) -> Coach:
    return request.app.state.coach


async def _analyzer(request: Request) -> Analyzer:
    return request.app.state.analyzer


StoreDep = Annotated[Store, Depends(_store)]
WorkerDep = Annotated[Worker, Depends(_worker)]
CoachDep = Annotated[Coach, Depends(_coach)]
AnalyzerDep = Annotated[Analyzer, Depends(_analyzer)]


def path_id(value: str, field: str) -> str:
    """An id in a path of a create or update: it must be a UUID."""
    try:
        return parse_id(value)
    except ValueError as exc:
        raise validation_error(field, str(exc)) from None


def lookup_id(value: str) -> str:
    """An id in a path of a read: the canonical form, so any case finds the row."""
    return value.lower()


def _require_take(store: Store, take_id: str) -> dict[str, Any]:
    take = store.get_take(lookup_id(take_id))
    if take is None:
        raise not_found("take", take_id)
    return take


# -- health ------------------------------------------------------------------------------------


@router.get("/health")
def health(request: Request, store: StoreDep, coach: CoachDep) -> dict[str, Any]:
    return {
        "status": "ok",
        "api_version": "v1",
        "server_version": _server_version(),
        "stt_engine": request.app.state.stt_engine,
        "coaching": coach.coaching_info(),
        "queue_length": store.queue_length(),
    }


# -- sessions ----------------------------------------------------------------------------------


@router.put("/sessions/{session_id}")
def put_session(
    session_id: str, body: SessionCreate, response: Response, store: StoreDep
) -> dict[str, Any]:
    session_id = path_id(session_id, "session_id")
    try:
        row, created = store.create_session(
            id=session_id,
            mode=body.mode,
            started_at=body.started_at,
            nervousness_before=body.nervousness_before,
        )
    except Conflict as exc:
        raise ApiError(409, "conflict", str(exc)) from None
    response.status_code = 201 if created else 200
    return resources.session_resource(row)


@router.patch("/sessions/{session_id}")
def patch_session(session_id: str, body: SessionPatch, store: StoreDep) -> dict[str, Any]:
    session_id = lookup_id(session_id)
    session = store.get_session(session_id)
    if session is None:
        raise not_found("session", session_id)
    changes = body.model_dump(exclude_unset=True)
    if "ended_at" in changes and changes["ended_at"] is None:
        if session["ended_at"] is not None:
            raise validation_error("ended_at", "cannot be cleared once set")
        del changes["ended_at"]
    if changes:
        session = store.update_session(session_id, changes) or session
    return resources.session_resource(session)


@router.get("/sessions")
def list_sessions(
    store: StoreDep,
    before: Annotated[str | None, Query()] = None,
    limit: Annotated[int, Query(ge=1, le=100)] = 20,
) -> dict[str, Any]:
    if before is None:
        bound = NO_UPPER_BOUND
    else:
        try:
            bound = normalize_ts(before)
        except ValueError:
            raise validation_error("before", "must be an RFC 3339 timestamp") from None
    rows = store.list_sessions(before=bound, limit=limit + 1)
    more = len(rows) > limit
    rows = rows[:limit]
    prompts = store.prompt_summaries([r["id"] for r in rows])
    sessions = []
    for row in rows:
        summaries = prompts[row["id"]]
        sessions.append(
            {
                **resources.session_resource(row),
                "prompts": [
                    {
                        "id": p["id"],
                        "kind": p["kind"],
                        "language": p["language"],
                        "text": p["text"],
                        "take_count": p["take_count"],
                    }
                    for p in summaries
                ],
                "take_count": sum(p["take_count"] for p in summaries),
            }
        )
    return {"sessions": sessions, "next_before": rows[-1]["started_at"] if more else None}


def _prompts_with_takes(store: Store, prompts: list[dict[str, Any]]) -> list[dict[str, Any]]:
    takes = store.list_takes([p["id"] for p in prompts])
    return [
        {
            **resources.prompt_resource(p),
            "takes": [resources.take_resource(t) for t in takes[p["id"]]],
        }
        for p in prompts
    ]


@router.get("/sessions/{session_id}")
def get_session(session_id: str, store: StoreDep) -> dict[str, Any]:
    session = store.get_session(lookup_id(session_id))
    if session is None:
        raise not_found("session", session_id)
    prompts = store.list_prompts(session["id"])
    return {**resources.session_resource(session), "prompts": _prompts_with_takes(store, prompts)}


# -- questions and prompts ---------------------------------------------------------------------


@router.post("/questions")
def post_questions(body: QuestionsRequest, store: StoreDep, coach: CoachDep) -> dict[str, Any]:
    exclude = list(dict.fromkeys([*body.exclude, *store.recent_impromptu_texts(RECENT_QUESTIONS)]))
    if body.track == "work":
        return coach.generate_questions(
            count=body.count,
            category=body.category,
            exclude=exclude,
            track="work",
            language=body.language,
        )
    themes = [t["name"] for t in store.list_themes()]
    theme = body.theme
    if theme is not None:
        # A theme Ryan has keeps its own spelling, so its takes are counted together.
        theme = next((name for name in themes if name.lower() == theme.lower()), theme)
    interests = {
        "theme": theme,
        "takes": store.interest_take_count(theme),
        "themes": themes,
        "topics": store.recent_typed_topics(TOPICS_FOR_QUESTIONS),
    }
    return coach.generate_questions(
        count=body.count,
        category=None,
        exclude=exclude,
        track="interests",
        language=body.language,
        interests=interests,
    )


@router.put("/prompts/{prompt_id}")
def put_prompt(
    prompt_id: str, body: PromptCreate, response: Response, store: StoreDep
) -> dict[str, Any]:
    prompt_id = path_id(prompt_id, "prompt_id")
    try:
        row, created = store.create_prompt(
            id=prompt_id,
            session_id=body.session_id,
            kind=body.kind,
            text=body.text,
            notes=body.notes,
            category=body.category,
            target_seconds=body.target_seconds,
            question_source=body.question_source,
            language=body.language,
            theme=body.theme,
        )
    except Conflict as exc:
        raise ApiError(409, "conflict", str(exc)) from None
    except LookupError:
        raise unknown_parent("session_id", body.session_id) from None
    response.status_code = 201 if created else 200
    return resources.prompt_resource(row)


@router.get("/prompts/{prompt_id}")
def get_prompt(prompt_id: str, store: StoreDep) -> dict[str, Any]:
    prompt = store.get_prompt(lookup_id(prompt_id))
    if prompt is None:
        raise not_found("prompt", prompt_id)
    return _prompts_with_takes(store, [prompt])[0]


# -- themes ------------------------------------------------------------------------------------


def _learn_themes(store: Store, coach: Coach) -> None:
    """Relearn the learned themes when Ryan has typed topics the last learning has not read.

    Never raises: without a key, or when Claude fails, the current themes stay. A failure waits
    THEME_RETRY_AFTER before the next try, so Home does not wait on a failing call every time.
    """
    newest = store.newest_typed_prompt_at()
    state = store.theme_learning()
    if newest is None or (state["learned_through"] or "") >= newest:
        return
    if not coach.coaching_info().get("available"):
        return
    if state["failed_at"] is not None:
        failed = datetime.fromisoformat(state["failed_at"])
        if datetime.fromisoformat(store.clock()) < failed + THEME_RETRY_AFTER:
            return
    themes = store.list_themes(include_hidden=True)
    try:
        names = coach.learn_themes(
            topics=store.recent_typed_topics(TOPICS_FOR_THEMES),
            current=[t["name"] for t in themes if not t["hidden"]],
            hidden=[t["name"] for t in themes if t["hidden"]],
        )
    except Exception:
        log.exception("theme learning raised; keeping the current themes")
        names = None
    if names is None:
        store.theme_learning_failed()
        return
    store.replace_learned_themes(names, through=newest)


@router.get("/themes")
def list_themes(store: StoreDep, coach: CoachDep) -> dict[str, Any]:
    _learn_themes(store, coach)
    return {"themes": [resources.theme_resource(t) for t in store.list_themes()]}


@router.post("/themes")
def post_theme(body: ThemeCreate, response: Response, store: StoreDep) -> dict[str, Any]:
    theme, created = store.add_theme(body.name)
    response.status_code = 201 if created else 200
    return resources.theme_resource(theme)


@router.patch("/themes/{theme_id}")
def patch_theme(theme_id: str, body: ThemePatch, store: StoreDep) -> dict[str, Any]:
    theme = store.set_theme_pinned(lookup_id(theme_id), body.pinned)
    if theme is None:
        raise not_found("theme", theme_id)
    return resources.theme_resource(theme)


@router.delete("/themes/{theme_id}", status_code=204)
def delete_theme(theme_id: str, store: StoreDep) -> Response:
    if not store.remove_theme(lookup_id(theme_id)):
        raise not_found("theme", theme_id)
    return Response(status_code=204)


# -- takes -------------------------------------------------------------------------------------


def _validation_error_from(exc: ValidationError) -> ApiError:
    return ApiError(
        422,
        "validation_failed",
        "A field failed validation.",
        validation_details(exc.errors()),
    )


async def _read_metadata(part: Any) -> TakeMetadata:
    if isinstance(part, UploadFile):
        raw: str | bytes = await part.read()
    elif isinstance(part, str):
        raw = part
    else:
        raise ApiError(400, "bad_request", "The upload needs a `metadata` part with JSON.")
    try:
        data = json.loads(raw)
    except ValueError:
        raise ApiError(400, "bad_request", "The `metadata` part is not valid JSON.") from None
    if not isinstance(data, dict):
        raise ApiError(400, "bad_request", "The `metadata` part must be a JSON object.")
    try:
        return TakeMetadata.model_validate(data)
    except ValidationError as exc:
        raise _validation_error_from(exc) from None


def _stage_audio(upload: UploadFile, tmp_dir: Path) -> tuple[Path, str]:
    """Copy the upload to a temporary file on the data volume while hashing it.

    Returns the path and the SHA-256. Raises 415 for a file that is not a WAV and 413 for one
    over the size limit.
    """
    tmp_dir.mkdir(parents=True, exist_ok=True)
    descriptor, name = tempfile.mkstemp(dir=tmp_dir, suffix=".wav")
    path = Path(name)
    digest = hashlib.sha256()
    size = 0
    try:
        with os.fdopen(descriptor, "wb") as out:
            upload.file.seek(0)
            while chunk := upload.file.read(1024 * 1024):
                if size == 0 and not (chunk[:4] == b"RIFF" and chunk[8:12] == b"WAVE"):
                    raise ApiError(415, "unsupported_media_type", "The audio must be a WAV file.")
                size += len(chunk)
                if size > MAX_AUDIO_BYTES:
                    raise ApiError(413, "payload_too_large", "The audio is over 100 MB.")
                digest.update(chunk)
                out.write(chunk)
            out.flush()
            fsync_fd(out.fileno())
        if size == 0:
            raise ApiError(415, "unsupported_media_type", "The audio must be a WAV file.")
    except BaseException:
        path.unlink(missing_ok=True)
        raise
    return path, digest.hexdigest()


@router.put("/takes/{take_id}")
async def put_take(
    take_id: str, request: Request, response: Response, store: StoreDep, worker: WorkerDep
) -> dict[str, Any]:
    take_id = path_id(take_id, "take_id")
    length = request.headers.get("content-length", "")
    if length.isdigit() and int(length) > MAX_AUDIO_BYTES + MULTIPART_OVERHEAD:
        raise ApiError(413, "payload_too_large", "The audio is over 100 MB.")
    form = await request.form()
    staged: Path | None = None
    try:
        meta = await _read_metadata(form.get("metadata"))
        audio = form.get("audio")
        if not isinstance(audio, UploadFile):
            raise ApiError(400, "bad_request", "The upload needs an `audio` file part.")

        existing = store.get_take(take_id)
        if existing is not None:
            if existing["audio_sha256"] != meta.audio_sha256:
                raise ApiError(
                    409, "conflict", f"Take {take_id} already exists with different audio."
                )
            response.status_code = 200
            return resources.take_resource(existing)
        if store.get_prompt(meta.prompt_id) is None:
            raise unknown_parent("prompt_id", meta.prompt_id)

        staged, digest = await run_in_threadpool(_stage_audio, audio, store.tmp_dir)
        if digest != meta.audio_sha256:
            raise validation_error("audio_sha256", "does not match the uploaded audio")
        try:
            take, created = await run_in_threadpool(
                lambda: store.create_take(
                    id=take_id,
                    prompt_id=meta.prompt_id,
                    attempt=meta.attempt,
                    recorded_at=meta.recorded_at,
                    duration_s=meta.duration_s,
                    mic_route=meta.mic_route,
                    audio_sha256=meta.audio_sha256,
                    staged_audio=staged,
                )
            )
        except Conflict as exc:
            raise ApiError(409, "conflict", str(exc)) from None
        except LookupError:
            raise unknown_parent("prompt_id", meta.prompt_id) from None
    finally:
        if staged is not None:
            staged.unlink(missing_ok=True)
        await form.close()
    response.status_code = 201 if created else 200
    if created:
        worker.wake()
    return resources.take_resource(take)


@router.get("/takes/{take_id}")
def get_take(take_id: str, store: StoreDep) -> dict[str, Any]:
    return resources.take_resource(_require_take(store, take_id))


@router.get("/takes/{take_id}/report")
def get_report(take_id: str, store: StoreDep) -> dict[str, Any]:
    take = _require_take(store, take_id)
    if take["status"] not in ("coaching", "done") or take["analysis_id"] is None:
        raise ApiError(
            409,
            "not_ready",
            "The report is not ready yet.",
            {"status": take["status"]},
        )
    docs = store.analysis_docs(take["analysis_id"])
    prompt = store.get_prompt(take["prompt_id"])
    assert docs is not None and prompt is not None
    coaching = (
        store.coaching_doc(take["coaching_id"]) if take["coaching_status"] == "done" else None
    )
    return {
        "take": resources.take_resource(take),
        "prompt": resources.prompt_resource(prompt),
        "analysis": docs[1],
        "coaching": coaching,
        "has_comparison": take["previous_take_id"] is not None,
    }


@router.get("/takes/{take_id}/comparison")
def get_comparison(take_id: str, store: StoreDep, analyzer: AnalyzerDep) -> dict[str, Any]:
    take = _require_take(store, take_id)
    no_previous = ApiError(
        404, "no_previous_take", "There is no earlier finished take of this prompt to compare."
    )
    if take["attempt"] == 1:
        raise no_previous
    if take["status"] != "done":
        raise ApiError(
            409,
            "not_ready",
            "The comparison is not ready yet.",
            {"status": take["status"]},
        )
    previous = store.get_take(take["previous_take_id"]) if take["previous_take_id"] else None
    if previous is None or previous["status"] != "done":
        raise no_previous
    docs = store.analysis_docs(take["analysis_id"])
    previous_docs = store.analysis_docs(previous["analysis_id"])
    assert docs is not None and previous_docs is not None
    return resources.compose_comparison(
        take=take,
        previous=previous,
        coaching=store.coaching_doc(take["coaching_id"]),
        previous_coaching=store.coaching_doc(previous["coaching_id"]),
        metric_changes=analyzer.compare_metrics(previous_docs[1], docs[1]),
    )


@router.get("/takes/{take_id}/audio")
def get_audio(take_id: str, store: StoreDep) -> FileResponse:
    take = _require_take(store, take_id)
    path = store.original_path(take["id"])
    if not path.is_file():
        raise not_found("audio for take", take_id)
    return FileResponse(path, media_type="audio/wav")


@router.post("/takes/{take_id}/reprocess", status_code=202)
def reprocess(
    take_id: str, body: ReprocessRequest, store: StoreDep, worker: WorkerDep
) -> dict[str, Any]:
    take_id = lookup_id(take_id)
    try:
        take = store.reprocess(take_id, body.from_stage)
    except InvalidState as exc:
        raise ApiError(409, "invalid_state", str(exc)) from None
    if take is None:
        raise not_found("take", take_id)
    worker.wake()
    return resources.take_resource(take)
