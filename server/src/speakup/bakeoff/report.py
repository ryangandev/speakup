"""Markdown report of a bake-off run."""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

from speakup.bakeoff.align import Pair
from speakup.bakeoff.metrics import (
    GoldScore,
    PauseScore,
    score_against_gold,
    score_pauses,
    word_gaps,
)
from speakup.bakeoff.vad import reference_pauses
from speakup.stt import Engine, Transcript
from speakup.text import Token, tokens_from_text, tokens_from_words

DRAFT_MARKER = "# DRAFT"


@dataclass
class EngineTotals:
    clips: int = 0
    gold_clips: int = 0
    words: int = 0
    filled: int = 0
    audio_seconds: float = 0.0
    elapsed_seconds: float = 0.0
    gold: GoldScore = field(default_factory=GoldScore)
    pauses: PauseScore = field(default_factory=PauseScore)


def is_draft(gold_text: str) -> bool:
    return any(line.startswith(DRAFT_MARKER) for line in gold_text.splitlines())


def _pct(value: float | None) -> str:
    return "-" if value is None else f"{100 * value:.0f}%"


def _num(value: float | None, digits: int = 0) -> str:
    return "-" if value is None else f"{value:.{digits}f}"


def _diff_line(pairs: list[Pair]) -> str:
    """Gold text with the engine's differences: ~~missed~~, **added**, ~~gold~~**engine**.
    Missed filled pauses and repetitions are what matter most, so they stand out."""
    out = []
    for p in pairs:
        if p.op == "match":
            out.append(str(p.hyp))
        elif p.op == "del":
            out.append(f"~~{p.gold}~~")
        elif p.op == "ins":
            out.append(f"**{p.hyp}**")
        else:
            out.append(f"~~{p.gold}~~**{p.hyp}**")
    return " ".join(out)


def _highlight_fillers(tokens: list[Token]) -> str:
    return " ".join(f"**{t}**" if t.is_filled_pause else str(t) for t in tokens)


def build_report(
    data_dir: Path,
    clips: dict[str, Path],
    engines: dict[str, Engine],
) -> Path:
    transcripts_dir = data_dir / "transcripts"
    gold_dir = data_dir / "gold"
    clip_dir = data_dir / "report"
    clip_dir.mkdir(parents=True, exist_ok=True)

    engine_names = [
        name
        for name in engines
        if (transcripts_dir / name).is_dir() and any((transcripts_dir / name).glob("*.json"))
    ]
    totals = {name: EngineTotals() for name in engine_names}
    gold_status: dict[str, str] = {}

    for clip, wav_path in sorted(clips.items()):
        reference = reference_pauses(wav_path)
        gold_path = gold_dir / f"{clip}.txt"
        gold_tokens: list[Token] | None = None
        if gold_path.exists():
            gold_text = gold_path.read_text()
            if is_draft(gold_text):
                gold_status[clip] = "draft, not corrected yet"
            else:
                gold_tokens = tokens_from_text(gold_text)
                gold_status[clip] = f"{len(gold_tokens)} words"
        else:
            gold_status[clip] = "none"

        lines = [f"# {clip}", "", f"Reference pauses (VAD, 250 ms or more): {len(reference)}", ""]
        if gold_tokens is not None:
            lines += ["Gold, with filled pauses in bold:", "", _highlight_fillers(gold_tokens), ""]
            lines += ["Engine lines show the gold text with ~~missed~~ and **added** words.", ""]

        for name in engine_names:
            path = transcripts_dir / name / f"{clip}.json"
            if not path.exists():
                continue
            transcript = Transcript.load(path)
            tokens = tokens_from_words(transcript.words)
            t = totals[name]
            t.clips += 1
            t.words += len(tokens)
            t.filled += sum(tok.is_filled_pause for tok in tokens)
            t.audio_seconds += transcript.audio_seconds
            t.elapsed_seconds += transcript.elapsed_seconds
            pause = score_pauses(reference, word_gaps(tokens))
            t.pauses.add(pause)

            lines += [f"## {name}", ""]
            lines.append(
                f"{len(tokens)} words, {sum(tok.is_filled_pause for tok in tokens)} filled pauses, "
                f"pauses found {pause.matched} of {pause.reference}, "
                f"{transcript.elapsed_seconds:.1f} s to transcribe."
            )
            lines.append("")
            if gold_tokens is not None:
                score = score_against_gold(gold_tokens, tokens)
                t.gold.add(score)
                t.gold_clips += 1
                lines.append(
                    f"WER {_pct(score.wer)}, filled pauses {score.filled_found} of "
                    f"{score.filled_gold}, "
                    f"repetitions {score.repeats_kept} of {score.repeats_gold}, "
                    f"cut-offs {score.cutoffs_kept} of {score.cutoffs_gold}."
                )
                lines += ["", _diff_line(score.pairs), ""]
            else:
                lines += [_highlight_fillers(tokens), ""]
        (clip_dir / f"{clip}.md").write_text("\n".join(lines))

    gold_clips = sum(1 for s in gold_status.values() if s.endswith("words"))
    out = [
        "# Speech-to-text bake-off",
        "",
        f"{len(clips)} clips, {gold_clips} with a corrected gold transcript.",
        "Per-clip transcripts and differences are in [report/](report/).",
        "",
        "## Against your corrected transcripts",
        "",
    ]
    if gold_clips:
        out += [
            "| Engine | Clips | Verbatim WER | Filled pauses found | Filled pause precision "
            "| Repetitions kept | Cut-offs kept |",
            "| --- | --- | --- | --- | --- | --- | --- |",
        ]
        for name in engine_names:
            g = totals[name].gold
            out.append(
                f"| {name} | {totals[name].gold_clips} | {_pct(g.wer)} | {_pct(g.filled_recall)} "
                f"| {_pct(g.filled_precision)} | {_pct(g.repeats_recall)} "
                f"| {_pct(g.cutoffs_recall)} |"
            )
    else:
        out.append(
            "No corrected gold transcripts yet. Run `draft-gold`, correct the drafts, "
            "and delete their DRAFT line."
        )
    out += [
        "",
        "## All clips",
        "",
        "| Engine | Clips | Filled pauses per 100 words | Pauses found (vs VAD) "
        "| Pause precision | Pause edge error | Speed | Cost per hour |",
        "| --- | --- | --- | --- | --- | --- | --- | --- |",
    ]
    for name in engine_names:
        t = totals[name]
        rate = 100 * t.filled / t.words if t.words else None
        speed = t.audio_seconds / t.elapsed_seconds if t.elapsed_seconds else None
        out.append(
            f"| {name} | {t.clips} | {_num(rate, 1)} | {_pct(t.pauses.recall)} "
            f"| {_pct(t.pauses.precision)} | {_num(t.pauses.boundary_error_ms)} ms "
            f"| {_num(speed, 1)}x real time | ${engines[name].cost_per_hour_usd:.2f} |"
        )
    out += [
        "",
        "## Gold transcripts",
        "",
        *[f"- {clip}: {status}" for clip, status in sorted(gold_status.items())],
        "",
        "## How to read this",
        "",
        "- **Verbatim WER** counts every word, fillers included, so it is higher than the WER "
        'vendors quote. Number formatting ("nine thirty" vs "9:30") also counts as an error.',
        "- **Filled pauses found** is the share of your um, uh and hmm the engine wrote down. "
        "This is the most important column. Precision is the share of the engine's filled "
        "pauses that you actually said.",
        '- **Repetitions kept** is the share of repeated words ("we we") the engine kept. '
        "**Cut-offs kept** is the share of broken-off words it wrote in any form.",
        "- **Pauses found** compares the gaps between the engine's words with pauses detected "
        "by voice activity detection (VAD). VAD has its own error, so treat small differences "
        "as noise. **Pause edge error** is how far the engine's word edges are from VAD's.",
        "- **Speed** excludes model loading. Cloud speeds include the network.",
        '- Lexical fillers (like, so, you know) are not scored: deciding whether "like" is a '
        "filler needs context, which is the coaching stage's job.",
        "- Gold drafts start from one engine's output, which can bias you toward it. "
        "Listen to the audio while correcting.",
        "- The Apple engine reports one time range per text run; runs are usually single words.",
    ]
    report_path = data_dir / "report.md"
    report_path.write_text("\n".join(out) + "\n")
    return report_path
