"""The FastAPI application."""

from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI

from speakup.api import defaults
from speakup.api.auth import BearerAuthMiddleware
from speakup.api.errors import install_error_handlers
from speakup.api.routes import router
from speakup.config import server_settings
from speakup.pipeline import Analyzer, Coach, Worker
from speakup.store import Store

MIN_TOKEN_LENGTH = 32
TOKEN_HELP = 'Generate one with: python3 -c "import secrets; print(secrets.token_urlsafe(32))"'


def create_app(
    *,
    store: Store | None = None,
    worker: Worker | None = None,
    coach: Coach | None = None,
    analyzer: Analyzer | None = None,
    token: str | None = None,
) -> FastAPI:
    """Build the app. Defaults build the real store, engine, analysis and coaching from settings;
    tests pass fakes.

    `analyzer` and `token` are additions to the contract's signature: the comparison endpoint
    needs `compare_metrics` (it defaults to the worker's analyzer), and tests pass the token.
    """
    settings = server_settings()
    token = token or settings.api_token
    if not token:
        raise RuntimeError(f"SPEAKUP_API_TOKEN is not set. Put one in server/.env. {TOKEN_HELP}")
    if len(token) < MIN_TOKEN_LENGTH:
        raise RuntimeError(
            f"SPEAKUP_API_TOKEN is only {len(token)} characters; it needs at least "
            f"{MIN_TOKEN_LENGTH}. {TOKEN_HELP}"
        )

    if worker is not None:
        store = store or worker.store
        analyzer = analyzer or worker.analyzer
        coach = coach or worker.coach
    store = store or defaults.default_store(settings)
    analyzer = analyzer or defaults.load_analyzer()
    coach = coach or defaults.load_coach()
    if worker is None:
        worker = Worker(store, defaults.default_engine(settings), analyzer, coach)

    @asynccontextmanager
    async def lifespan(_: FastAPI) -> AsyncIterator[None]:
        worker.start()
        try:
            yield
        finally:
            worker.stop()

    app = FastAPI(
        title="SpeakUp server",
        lifespan=lifespan,
        docs_url=None,
        redoc_url=None,
        openapi_url=None,
    )
    app.state.store = store
    app.state.worker = worker
    app.state.coach = coach
    app.state.analyzer = analyzer
    app.state.stt_engine = worker.engine.name
    install_error_handlers(app)
    app.include_router(router)
    app.add_middleware(BearerAuthMiddleware, token=token)
    return app
