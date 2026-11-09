"""Command line for the M0 speech-to-text bake-off.

Put recordings in data/bakeoff/clips/, then:

    uv run speakup-bakeoff engines
    uv run speakup-bakeoff transcribe
    uv run speakup-bakeoff draft-gold
    uv run speakup-bakeoff report
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

from speakup.audio import AUDIO_SUFFIXES, duration_seconds, to_wav16k
from speakup.bakeoff.report import DRAFT_MARKER, build_report
from speakup.config import REPO_DIR
from speakup.stt import Engine, Transcript
from speakup.stt.registry import all_engines

DEFAULT_DATA_DIR = REPO_DIR / "data" / "bakeoff"

GOLD_HEADER = f"""{DRAFT_MARKER}: delete this line once you have corrected the text below.
# Gold transcript for {{clip}}, drafted from {{engine}}. Do not trust the draft.
# Listen to the recording and edit the text until it is exactly what you said:
# - Write every um, uh and hmm where you said it.
# - Write repeated words each time: "we we need to".
# - End a broken-off word with a hyphen: "th- the database".
# - Do not fix grammar. Lines starting with # are ignored.

"""


def prepare_clips(data_dir: Path, only: list[str] | None) -> dict[str, Path]:
    """Convert every recording in clips/ to 16 kHz mono WAV in wav/, reusing fresh copies."""
    clips_dir = data_dir / "clips"
    if not clips_dir.is_dir():
        sys.exit(f"Put your recordings in {clips_dir} first.")
    clips: dict[str, Path] = {}
    for src in sorted(clips_dir.iterdir()):
        if src.suffix.lower() not in AUDIO_SUFFIXES or (only and src.stem not in only):
            continue
        if src.stem in clips:
            sys.exit(f"Two recordings are named {src.stem}; rename one.")
        wav = data_dir / "wav" / f"{src.stem}.wav"
        if not wav.exists() or wav.stat().st_mtime < src.stat().st_mtime:
            to_wav16k(src, wav)
        clips[src.stem] = wav
    if not clips:
        sys.exit(f"No recordings found in {clips_dir}.")
    return clips


def selected_engines(names: str | None) -> dict[str, Engine]:
    engines = all_engines()
    if not names:
        return {n: e for n, e in engines.items() if e.missing_config() is None}
    picked = {}
    for name in names.split(","):
        if name not in engines:
            sys.exit(f"Unknown engine {name}. Known: {', '.join(engines)}")
        if problem := engines[name].missing_config():
            sys.exit(f"{name} cannot run: {problem}")
        picked[name] = engines[name]
    return picked


def cmd_engines(_: argparse.Namespace) -> None:
    engines = all_engines()
    width = max(len(e.description) for e in engines.values())
    for name, engine in engines.items():
        problem = engine.missing_config()
        status = "ready" if problem is None else f"not ready: {problem}"
        print(f"{name:14} {engine.description:{width}}  {status}")


def cmd_transcribe(args: argparse.Namespace) -> None:
    clips = prepare_clips(args.data, args.clips)
    engines = selected_engines(args.engines)
    if not engines:
        sys.exit("No engine is ready. Run `speakup-bakeoff engines` to see what is missing.")
    for name, engine in engines.items():
        todo = {
            clip: wav
            for clip, wav in clips.items()
            if args.force or not (args.data / "transcripts" / name / f"{clip}.json").exists()
        }
        if not todo:
            print(f"{name}: all {len(clips)} clips already transcribed")
            continue
        started = time.perf_counter()
        engine.prepare()
        print(f"{name}: ready in {time.perf_counter() - started:.1f} s")
        for clip, wav in todo.items():
            seconds = duration_seconds(wav)
            started = time.perf_counter()
            try:
                transcript = engine.transcribe(wav, seconds)
            except Exception as error:  # noqa: BLE001 - one failed clip must not stop the run
                print(f"  {clip}: FAILED: {error}")
                continue
            transcript.elapsed_seconds = time.perf_counter() - started
            transcript.save(args.data / "transcripts" / name / f"{clip}.json")
            print(
                f"  {clip}: {len(transcript.words)} words, {seconds:.0f} s of audio "
                f"in {transcript.elapsed_seconds:.1f} s"
            )


def cmd_draft_gold(args: argparse.Namespace) -> None:
    clips = prepare_clips(args.data, args.clips)
    gold_dir = args.data / "gold"
    gold_dir.mkdir(parents=True, exist_ok=True)
    for clip in clips:
        out = gold_dir / f"{clip}.txt"
        if out.exists() and not args.force:
            print(f"{clip}: gold exists, skipped")
            continue
        source = args.data / "transcripts" / args.engine / f"{clip}.json"
        if not source.exists():
            print(f"{clip}: no {args.engine} transcript yet; run transcribe first")
            continue
        text = Transcript.load(source).text.strip()
        out.write_text(GOLD_HEADER.format(clip=clip, engine=args.engine) + text + "\n")
        print(f"{clip}: draft written to {out}")


def cmd_report(args: argparse.Namespace) -> None:
    clips = prepare_clips(args.data, args.clips)
    path = build_report(args.data, clips, all_engines())
    print(f"Report written to {path}")


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(
        prog="speakup-bakeoff",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--data",
        type=Path,
        default=DEFAULT_DATA_DIR,
        help=f"bake-off folder (default: {DEFAULT_DATA_DIR})",
    )
    parser.add_argument(
        "--clips",
        type=lambda s: s.split(","),
        help="comma-separated clip names (file names without extension)",
    )
    commands = parser.add_subparsers(dest="command", required=True)

    commands.add_parser("engines", help="list engines and whether each can run")

    transcribe = commands.add_parser("transcribe", help="run engines on every clip")
    transcribe.add_argument("--engines", help="comma-separated engine names (default: all ready)")
    transcribe.add_argument("--force", action="store_true", help="redo existing transcripts")

    draft = commands.add_parser("draft-gold", help="write gold transcript drafts to correct")
    draft.add_argument("--engine", default="scribe", help="engine to draft from (default: scribe)")
    draft.add_argument("--force", action="store_true", help="overwrite existing gold files")

    commands.add_parser("report", help="score engines and write report.md")

    args = parser.parse_args(argv)
    {
        "engines": cmd_engines,
        "transcribe": cmd_transcribe,
        "draft-gold": cmd_draft_gold,
        "report": cmd_report,
    }[args.command](args)


if __name__ == "__main__":
    main()
