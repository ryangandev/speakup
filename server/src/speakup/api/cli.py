"""`speakup-server`: run the API on 127.0.0.1 (published to the tailnet by `tailscale serve`)."""

from __future__ import annotations

import logging
import sys

import uvicorn

from speakup.config import server_settings

HOST = "127.0.0.1"


def main() -> int:
    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s"
    )
    try:
        settings = server_settings()
        # Imported here so a missing module is reported as a startup error, not an import error.
        from speakup.api.app import create_app

        app = create_app()
    except (RuntimeError, ValueError) as exc:
        print(f"speakup-server: {exc}", file=sys.stderr)
        return 2
    uvicorn.run(app, host=HOST, port=settings.port, log_level="info", server_header=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
