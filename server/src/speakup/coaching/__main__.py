"""Developer command for iterating on the coaching prompt with real takes.

    uv run python -m speakup.coaching <analysis.json> --prompt "Why did we ..."
    uv run python -m speakup.coaching <analysis.json> --previous <analysis.json> \\
        --previous-report <report.json>

Prints the coaching report as JSON on stdout and token usage on stderr.
`--dry-run` prints the request instead and needs no API key.
"""

from __future__ import annotations

import argparse
import json
import sys
import uuid
from pathlib import Path
from typing import Any

from .coach import CoachingRequest, build_request, coach_take_with_usage
from .errors import CoachingFailed, CoachingUnavailable


def _load(path: str) -> dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="python -m speakup.coaching",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("analysis", help="rules-only analysis JSON of the take")
    parser.add_argument("--previous", help="finalized analysis JSON of the previous take")
    parser.add_argument("--previous-report", help="coaching report JSON of the previous take")
    parser.add_argument("--prompt", default="", help="the question or prepared title")
    parser.add_argument("--kind", choices=["impromptu", "prepared"], default="impromptu")
    parser.add_argument(
        "--category", choices=["decision", "status", "explain", "pushback", "other"]
    )
    parser.add_argument("--notes", help="prepared notes, or @file to read them from a file")
    parser.add_argument("--target-seconds", type=int, default=90)
    parser.add_argument("--attempt", type=int, help="default: 2 with --previous, else 1")
    parser.add_argument("--dry-run", action="store_true", help="print the request, do not call")
    args = parser.parse_args(argv)
    if args.previous_report and not args.previous:
        parser.error("--previous-report needs --previous")
    return args


def build(args: argparse.Namespace) -> CoachingRequest:
    analysis = _load(args.analysis)
    notes = args.notes
    if notes and notes.startswith("@"):
        notes = Path(notes[1:]).read_text(encoding="utf-8")
    previous = None
    if args.previous:
        previous = {
            "attempt": (args.attempt or 2) - 1,
            "analysis": _load(args.previous),
            "coaching": _load(args.previous_report) if args.previous_report else None,
        }
    return {
        "take_id": analysis.get("take_id") or str(uuid.uuid4()),
        "mode": "home",
        "prompt": {
            "kind": args.kind,
            "text": args.prompt or "(prompt not given)",
            "notes": notes if args.kind == "prepared" else None,
            "category": args.category if args.kind == "impromptu" else None,
            "target_seconds": args.target_seconds,
        },
        "attempt": args.attempt or (2 if previous else 1),
        "analysis": analysis,
        "previous": previous,
    }


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    request = build(args)
    if args.dry_run:
        params = build_request(request)
        print(params["system"][0]["text"])
        print("=" * 72)
        print(params["messages"][0]["content"][0]["text"])
        return 0
    try:
        report, usages = coach_take_with_usage(request)
    except CoachingUnavailable as exc:
        print(
            f"Coaching unavailable: {exc}. Add ANTHROPIC_API_KEY to server/.env.", file=sys.stderr
        )
        return 2
    except CoachingFailed as exc:
        print(f"Coaching failed: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(report, indent=2, ensure_ascii=False))
    for i, usage in enumerate(usages, 1):
        print(f"call {i} usage: {usage}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
