"""Bearer-token check for every HTTP request, including health and unknown paths."""

from __future__ import annotations

import hmac

from starlette.types import ASGIApp, Receive, Scope, Send

from speakup.api.errors import error_response


class BearerAuthMiddleware:
    """A plain ASGI middleware, so a bad token is rejected before any body is read or parsed."""

    def __init__(self, app: ASGIApp, token: str) -> None:
        self.app = app
        self._token = token.encode()

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        header = ""
        for name, value in scope["headers"]:
            if name == b"authorization":
                header = value.decode("latin-1")
                break
        scheme, _, credential = header.partition(" ")
        if scheme.lower() == "bearer" and hmac.compare_digest(
            credential.strip().encode(), self._token
        ):
            await self.app(scope, receive, send)
            return
        response = error_response(
            401,
            "unauthorized",
            "Missing or invalid bearer token.",
            headers={"WWW-Authenticate": "Bearer"},
        )
        await response(scope, receive, send)
