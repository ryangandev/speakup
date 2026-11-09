"""The error body every non-2xx response has. See docs/architecture.md#errors."""

from __future__ import annotations

import logging
from typing import Any

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

log = logging.getLogger(__name__)


class ApiError(Exception):
    def __init__(
        self, status: int, code: str, message: str, details: dict[str, Any] | None = None
    ) -> None:
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message
        self.details = details


def error_body(code: str, message: str, details: dict[str, Any] | None = None) -> dict[str, Any]:
    return {"error": {"code": code, "message": message, "details": details}}


def error_response(
    status: int,
    code: str,
    message: str,
    details: dict[str, Any] | None = None,
    headers: dict[str, str] | None = None,
) -> JSONResponse:
    return JSONResponse(error_body(code, message, details), status_code=status, headers=headers)


def not_found(what: str, resource_id: str) -> ApiError:
    return ApiError(404, "not_found", f"No {what} with id {resource_id}.")


def unknown_parent(field: str, resource_id: str) -> ApiError:
    return ApiError(
        404,
        "not_found",
        f"No {field.removesuffix('_id')} with id {resource_id}.",
        {"field": field},
    )


def validation_error(field: str, message: str) -> ApiError:
    return ApiError(
        422,
        "validation_failed",
        "A field failed validation.",
        {"errors": [{"field": field, "message": message}]},
    )


def _field_name(location: tuple[Any, ...]) -> str:
    parts = [str(p) for p in location if p not in ("body", "query", "path")]
    return ".".join(parts)


def _message(raw: str) -> str:
    return raw.removeprefix("Value error, ")


def validation_details(errors: list[Any]) -> dict[str, Any]:
    """The `details` of a 422: `{field, message}` for each pydantic error."""
    return {
        "errors": [
            {"field": _field_name(tuple(e["loc"])), "message": _message(e["msg"])} for e in errors
        ]
    }


_HTTP_CODES = {400: "bad_request", 404: "not_found", 405: "bad_request"}


def install_error_handlers(app: FastAPI) -> None:
    @app.exception_handler(ApiError)
    async def _api_error(_: Request, exc: ApiError) -> JSONResponse:
        return error_response(exc.status, exc.code, exc.message, exc.details)

    @app.exception_handler(RequestValidationError)
    async def _validation(_: Request, exc: RequestValidationError) -> JSONResponse:
        errors = exc.errors()
        if any(e["type"] == "json_invalid" for e in errors):
            return error_response(400, "bad_request", "The request body is not valid JSON.")
        return error_response(
            422, "validation_failed", "A field failed validation.", validation_details(errors)
        )

    @app.exception_handler(StarletteHTTPException)
    async def _http(_: Request, exc: StarletteHTTPException) -> JSONResponse:
        code = _HTTP_CODES.get(exc.status_code, "bad_request")
        message = (
            "No such endpoint." if exc.status_code == 404 else str(exc.detail or "Bad request.")
        )
        return error_response(exc.status_code, code, message)

    @app.exception_handler(Exception)
    async def _internal(_: Request, exc: Exception) -> JSONResponse:
        log.error("Unhandled error", exc_info=exc)
        return error_response(500, "internal", "Something went wrong on the server.")
