"""Rules that find pauses and disfluencies in a timed transcript.

Every rule prefers missing an event to inventing one: the coach builds its feedback on these
marks, so a wrong mark is worse than a missing one. Each rule says what evidence it needs.
See docs/architecture.md#events and docs/product.md#metrics.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from speakup.analysis.thresholds import Thresholds
from speakup.analysis.words import (
    WordDoc,
    content_indexes,
    ends_clause,
    ends_sentence,
    final_punctuation,
)

EventDoc = dict[str, Any]
Segment = tuple[float, float]

# Lexical filler candidates (docs/architecture.md#events).
LEXICAL_SINGLE = {"like", "so", "basically", "actually", "right", "literally"}
LEXICAL_PAIRS = {("you", "know"), ("kind", "of"), ("sort", "of"), ("i", "mean")}

# Uses of a candidate that are certainly not fillers, so coaching is not asked about them:
# "I like", "looks like", "so that", "and so on", "the right one", "a kind of", "do you know".
_LIKE_AFTER = {
    "i", "you", "we", "they", "he", "she", "would", "i'd", "we'd", "you'd", "they'd", "do",
    "don't", "didn't", "does", "doesn't", "did", "really", "also", "to", "look", "looks",
    "looked", "looking", "seem", "seems", "seemed", "feel", "feels", "felt", "sound", "sounds",
    "sounded", "something", "nothing", "anything", "more", "much", "exactly",
}  # fmt: skip
_SO_BEFORE = {"think", "hope", "guess", "say", "said", "not", "or", "even", "just"}
_SO_AFTER = {"that", "far", "much", "many", "long", "few", "little"}
_RIGHT_BEFORE = {
    "the", "a", "that's", "is", "was", "all", "exactly", "turn", "turned", "your", "my", "our",
    "his", "her", "their", "its",
}  # fmt: skip
_RIGHT_AFTER = {
    "now", "away", "after", "before", "here", "there", "side", "thing", "way", "answer",
    "choice", "call", "decision", "one", "approach", "time", "place", "person", "tool",
}  # fmt: skip
_KIND_OF_AFTER = {
    "a", "the", "what", "this", "that", "which", "any", "some", "every", "one", "same",
    "different", "each", "no", "another", "these", "those",
}  # fmt: skip
_YOU_KNOW_AFTER = {"do", "did", "don't", "didn't", "if", "as", "would", "could", "will"}
_I_MEAN_AFTER = {"what"}

# Single words that are often doubled on purpose ("had had", "that that", "very very"); they count
# as a repetition only with a hesitation between the copies.
_DELIBERATE_DOUBLES = {"had", "that", "is", "very", "really", "bye", "no", "yes", "yeah", "ha"}

# Words that cannot end a phrase, so a restart right after one abandons the phrase: the "to" in
# "we need to - we should".
_INCOMPLETE_ENDINGS = {
    "a", "an", "the", "to", "of", "for", "with", "from", "in", "on", "at", "by", "about", "into",
    "and", "but", "or", "is", "are", "was", "were", "be", "been", "will", "would", "should",
    "could", "can", "must", "might", "need", "needs", "have", "has", "do", "does", "did", "my",
    "our", "your", "their", "his", "her", "its", "this", "these", "those", "some", "any", "very",
    "more", "most", "than", "if", "because",
}  # fmt: skip

# A pause before one of these starts a new clause.
_CLAUSE_STARTERS = {
    "and", "but", "or", "so", "because", "which", "who", "when", "where", "while", "if",
    "although", "though", "since", "unless", "whereas", "whether",
}  # fmt: skip
# Sentence-initial discourse markers; a pause right after one is a natural beat ("So, ... we").
_DISCOURSE_MARKERS = {
    "so", "okay", "ok", "well", "right", "yeah", "yes", "no", "now", "alright", "anyway", "sure",
}  # fmt: skip


@dataclass(frozen=True)
class Pause:
    start: float
    end: float
    before: int  # index of the word right after the silence


def event(
    type_: str,
    start: float,
    end: float,
    word_start: int,
    word_end: int,
    *,
    source: str = "rules",
    reason: str | None = None,
    repair_word: int | None = None,
    is_filler: bool | None = None,
    filler_resolution: str | None = None,
    note: str | None = None,
) -> EventDoc:
    return {
        "id": "",
        "type": type_,
        "start": round(start, 3),
        "end": round(end, 3),
        "word_start": word_start,
        "word_end": word_end,
        "source": source,
        "reason": reason,
        "repair_word": repair_word,
        "is_filler": is_filler,
        "filler_resolution": filler_resolution,
        "note": note,
    }


def sort_key(e: EventDoc) -> tuple[float, int, float]:
    return (e["start"], e["word_start"], e["end"])


# --- Voice track and pauses ------------------------------------------------------------------


def _union(segments: list[Segment]) -> list[Segment]:
    merged: list[Segment] = []
    for start, end in sorted(segments):
        if merged and start <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], end))
        else:
            merged.append((start, end))
    return merged


def overlap(segments: list[Segment], lo: float, hi: float) -> float:
    return sum(max(0.0, min(e, hi) - max(s, lo)) for s, e in segments)


def voice_track(
    words: list[WordDoc], speech: list[Segment], thresholds: Thresholds
) -> tuple[list[Segment], bool]:
    """The voiced segments analysis uses, and whether they come from voice activity detection.

    The VAD track is trusted when it covers most of the time the engine heard words. When it
    does not (whispering, noise, a VAD failure), the spoken words' own intervals stand in.
    """
    spoken = _union([(w["start"], w["end"]) for w in words if w["kind"] != "non_speech"])
    word_time = sum(e - s for s, e in spoken)
    if word_time > 0 and speech:
        covered = sum(overlap(speech, s, e) for s, e in spoken)
        if covered / word_time >= thresholds.vad_min_word_coverage:
            return _union(speech), True
    return spoken, False


def _silences(track: list[Segment], lo: float, hi: float) -> list[Segment]:
    """The parts of [lo, hi] that the track does not cover."""
    holes, cursor = [], lo
    for s, e in track:
        if e <= cursor:
            continue
        if s >= hi:
            break
        if s > cursor:
            holes.append((cursor, s))
        cursor = e
    if cursor < hi:
        holes.append((cursor, hi))
    return holes


def find_pauses(words: list[WordDoc], track: list[Segment], thresholds: Thresholds) -> list[Pause]:
    """Silences between adjacent spoken words, where the voice track and the word gap agree.

    The engine's gap must leave room for a pause, and the voice track must be silent for at
    least the pause threshold between the middles of the two words. The silence keeps its own
    edges, so a word the engine stretched over the silence does not shorten it. When the track
    hears nothing of one of the two words (a very quiet word), it cannot place the silence, and
    the engine's gap stands. Silences next to a sound such as laughter are not pauses.
    """
    pauses = []
    for a, b in zip(words, words[1:], strict=False):
        if "non_speech" in (a["kind"], b["kind"]):
            continue
        if round(b["start"] - a["end"], 3) < thresholds.pause_min_word_gap_s:
            continue
        if overlap(track, a["start"], a["end"]) == 0 or overlap(track, b["start"], b["end"]) == 0:
            candidates = [(a["end"], b["start"])]
        else:
            lo, hi = (a["start"] + a["end"]) / 2, (b["start"] + b["end"]) / 2
            candidates = [
                (s, e) for s, e in _silences(track, a["start"], b["end"]) if e > lo and s < hi
            ]
        if not candidates:
            continue
        start, end = max(candidates, key=lambda s: s[1] - s[0])
        if round(end - start, 3) >= thresholds.min_pause_s:
            pauses.append(Pause(start, end, b["i"]))
    return pauses


# --- Disfluencies ----------------------------------------------------------------------------


class _Transcript:
    """Read-only views of the words that every rule needs."""

    def __init__(self, words: list[WordDoc], pauses: list[Pause]) -> None:
        self.words = words
        self.content = content_indexes(words)
        self.position = {i: p for p, i in enumerate(self.content)}
        self.pause_before = {p.before: p for p in pauses}
        # An engine that writes no sentence punctuation at all hides every sentence boundary.
        self.punctuated = any(ends_sentence(words[i]) for i in self.content)

    def norm(self, i: int) -> str:
        return self.words[i]["norm"].replace("\N{RIGHT SINGLE QUOTATION MARK}", "'")

    def prev_content(self, i: int) -> int | None:
        """The last word of kind `word` before index i."""
        for j in range(i - 1, -1, -1):
            if self.words[j]["kind"] == "word":
                return j
        return None

    def next_content(self, i: int) -> int | None:
        """The first word of kind `word` at or after index i."""
        for j in range(i, len(self.words)):
            if self.words[j]["kind"] == "word":
                return j
        return None

    def hesitation_between(self, a: int, b: int) -> bool:
        """A filled pause or a silent pause between words a and b (a < b)."""
        if any(self.words[j]["kind"] == "filled_pause" for j in range(a + 1, b)):
            return True
        return any(j in self.pause_before for j in range(a + 1, b + 1))

    def sentence_initial(self, i: int) -> bool:
        prev = self.prev_content(i)
        return prev is None or ends_sentence(self.words[prev])


def _restarts_at_cutoffs(t: _Transcript, thresholds: Thresholds) -> list[EventDoc]:
    """A broken-off word ("nee-") and the abandoned start it ends.

    The abandoned start reaches back to the word the repair begins with, when the speaker
    restarts from it within a few words: "we nee- we picked" abandons "we nee-". Otherwise only
    the broken-off word is abandoned: "th- the team".
    """
    events = []
    words, content = t.words, t.content
    p = 0
    while p < len(content):
        if not words[content[p]]["cutoff"]:
            p += 1
            continue
        q = p
        while q + 1 < len(content) and words[content[q + 1]]["cutoff"]:
            q += 1
        start_word, last = content[p], content[q]
        repair = content[q + 1] if q + 1 < len(content) else None
        if repair is not None and not t.norm(repair).startswith(t.norm(content[p])):
            for back in range(1, thresholds.restart_lookback_words + 1):
                if p - back < 0:
                    break
                candidate = content[p - back]
                if words[candidate]["cutoff"] or ends_sentence(words[candidate]):
                    break
                if t.norm(candidate) == t.norm(repair):
                    start_word = candidate
                    break
        events.append(
            event(
                "restart",
                words[start_word]["start"],
                words[last]["end"],
                start_word,
                last + 1,
                reason="cutoff",
                repair_word=repair,
            )
        )
        p = q + 1
    return events


def _repetitions(t: _Transcript) -> list[EventDoc]:
    """Words or phrases of up to three words said again right away: "the the team",
    "I think, um, I think". Filled pauses between the copies do not break a repetition."""
    events = []
    words, content = t.words, t.content
    norms = [t.norm(i) for i in content]
    k = 0
    while k < len(content):
        for n in (3, 2, 1):
            if k + 2 * n > len(content):
                continue
            first, second = content[k : k + n], content[k + n : k + 2 * n]
            if norms[k : k + n] != norms[k + n : k + 2 * n]:
                continue
            if any(words[i]["cutoff"] for i in first + second):
                continue
            # "No. No, that is wrong" repeats across sentences on purpose.
            if ends_sentence(words[first[-1]]):
                continue
            if (
                n == 1
                and norms[k] in _DELIBERATE_DOUBLES
                and not t.hesitation_between(first[0], second[0])
            ):
                continue
            copies = 1
            while (
                k + (copies + 2) * n <= len(content)
                and norms[k + (copies + 1) * n : k + (copies + 2) * n] == norms[k : k + n]
                and not any(
                    words[i]["cutoff"] for i in content[k + (copies + 1) * n : k + (copies + 2) * n]
                )
            ):
                copies += 1
            last = content[k + (copies + 1) * n - 1]
            events.append(
                event(
                    "repetition",
                    words[first[0]]["start"],
                    words[last]["end"],
                    first[0],
                    last + 1,
                    reason="word" if n == 1 else "phrase",
                    repair_word=second[0],
                )
            )
            k += copies * n
            break
        else:
            k += 1
    return events


def _abandoned_phrases(t: _Transcript, taken: set[int], thresholds: Thresholds) -> list[EventDoc]:
    """A phrase given up whole and started again: "we need to - we should migrate".

    All of these must hold, because ordinary speech repeats words too ("we said we would"):
    the repair starts with the same word as the abandoned phrase; the abandoned phrase ends on a
    word that cannot end a phrase ("to", "the", "is"); and there is a break between them (a
    silent or filled pause, a comma, a dash or a trail-off).
    """
    events = []
    words, content = t.words, t.content
    p = 0
    while p < len(content):
        found = None
        for length in range(2, thresholds.abandoned_phrase_max_words + 1):
            q = p + length
            if q >= len(content):
                break
            span = content[p:q]
            if any(i in taken or words[i]["cutoff"] for i in span + [content[q]]):
                break
            if any(ends_sentence(words[i]) for i in span):
                break
            if t.norm(content[p]) != t.norm(content[q]):
                continue
            if [t.norm(i) for i in span] == [t.norm(i) for i in content[q : q + length]]:
                continue  # said again whole: a repetition, not a restart
            last = span[-1]
            if t.norm(last) not in _INCOMPLETE_ENDINGS:
                continue
            dash_between = any(
                words[j]["kind"] == "non_speech"
                and words[j]["text"].strip("-\N{EM DASH}\N{EN DASH}") == ""
                for j in range(last + 1, content[q])
            )
            if (
                t.hesitation_between(last, content[q])
                or dash_between
                or final_punctuation(words[last]) in {",", ";", "..."}
            ):
                found = (span, content[q])
                break
        if found is None:
            p += 1
            continue
        span, repair = found
        events.append(
            event(
                "restart",
                words[span[0]]["start"],
                words[span[-1]]["end"],
                span[0],
                span[-1] + 1,
                reason="abandoned_phrase",
                repair_word=repair,
            )
        )
        p = t.position[repair]
    return events


def _is_certainly_not_filler(phrase: tuple[str, ...], prev: str | None, nxt: str | None) -> bool:
    if phrase == ("like",):
        return prev in _LIKE_AFTER
    if phrase == ("so",):
        return prev in _SO_BEFORE or nxt in _SO_AFTER or (prev == "and" and nxt == "on")
    if phrase == ("right",):
        return prev in _RIGHT_BEFORE or nxt in _RIGHT_AFTER
    if phrase in {("kind", "of"), ("sort", "of")}:
        return prev in _KIND_OF_AFTER
    if phrase == ("you", "know"):
        return prev in _YOU_KNOW_AFTER
    if phrase == ("i", "mean"):
        return prev in _I_MEAN_AFTER
    return False


def _setoff_before(t: _Transcript, first: int) -> str | None:
    if first in t.pause_before:
        return "silence"
    for j in range(first - 1, -1, -1):
        kind = t.words[j]["kind"]
        if kind == "filled_pause":
            return "filled"
        if kind == "word":
            if ends_sentence(t.words[j]):
                return "start"
            return "punctuation" if ends_clause(t.words[j]) else None
    return "start"


def _setoff_after(t: _Transcript, last: int) -> str | None:
    if last + 1 in t.pause_before:
        return "silence"
    if final_punctuation(t.words[last]) not in {"", "..."}:
        return "punctuation"
    for j in range(last + 1, len(t.words)):
        kind = t.words[j]["kind"]
        if kind == "filled_pause":
            return "filled"
        if kind == "word":
            return None
    return "end"


def _lexical_fillers(t: _Transcript) -> list[EventDoc]:
    """Lexical filler candidates, with a cautious rules estimate of whether each is a filler.

    Coaching judges every candidate in context; this estimate stands only when coaching is
    unavailable, so it says "filler" only when the word is set off on both sides and a silence
    or commas on both sides mid-sentence show it is not doing grammatical work:
    "because, like, ... the".
    """
    events = []
    words, content = t.words, t.content
    p = 0
    while p < len(content):
        i = content[p]
        if words[i]["cutoff"]:
            p += 1
            continue
        pair = (t.norm(i), t.norm(content[p + 1])) if p + 1 < len(content) else None
        if t.norm(i) in {" ".join(x) for x in LEXICAL_PAIRS}:
            span = [i]
            phrase = tuple(t.norm(i).split())
        elif (
            pair in LEXICAL_PAIRS
            and content[p + 1] == i + 1
            and not words[content[p + 1]]["cutoff"]
        ):
            span = [i, i + 1]
            phrase = pair
        elif t.norm(i) in LEXICAL_SINGLE:
            span = [i]
            phrase = (t.norm(i),)
        else:
            p += 1
            continue
        p += len(span)
        prev = t.prev_content(span[0])
        nxt = t.next_content(span[-1] + 1)
        if _is_certainly_not_filler(
            phrase,
            t.norm(prev) if prev is not None else None,
            t.norm(nxt) if nxt is not None else None,
        ):
            continue
        before, after = _setoff_before(t, span[0]), _setoff_after(t, span[-1])
        is_filler = (
            before is not None
            and after is not None
            and ("silence" in (before, after) or before == after == "punctuation")
        )
        events.append(
            event(
                "lexical_filler",
                words[span[0]]["start"],
                words[span[-1]]["end"],
                span[0],
                span[-1] + 1,
                is_filler=is_filler,
                filler_resolution="rules",
            )
        )
    return events


def _filled_pauses(words: list[WordDoc]) -> list[EventDoc]:
    return [
        event("filled_pause", w["start"], w["end"], w["i"], w["i"] + 1)
        for w in words
        if w["kind"] == "filled_pause"
    ]


# --- Pause classification --------------------------------------------------------------------


def _classify_pause(
    t: _Transcript, pause: Pause, restart_points: set[int], filler_words: set[int]
) -> tuple[str, str]:
    """(type, reason) of a pause: a natural `boundary_pause` or a `block`.

    Boundaries come first, so a pause between sentences stays natural even when a filler
    follows it; the filler is marked on its own.
    """
    k = pause.before
    prev, nxt = t.prev_content(k), t.next_content(k)
    if prev is None or nxt is None or ends_sentence(t.words[prev]):
        return "boundary_pause", "sentence"
    # Without punctuation, a capital letter is the only sign of a new sentence. It also marks
    # names and "I" ("we moved to DynamoDB"), which costs a missed block rather than a false one.
    if not t.punctuated and t.words[nxt]["text"][:1].isupper():
        return "boundary_pause", "sentence"
    # Engines put commas around fillers ("because, like,"), so those commas mark no clause.
    if ends_clause(t.words[prev]) and prev not in filler_words:
        return "boundary_pause", "clause"
    if t.norm(nxt) in _CLAUSE_STARTERS and not t.words[nxt]["cutoff"]:
        return "boundary_pause", "clause"
    if t.norm(prev) in _DISCOURSE_MARKERS and t.sentence_initial(prev):
        return "boundary_pause", "clause"
    if t.words[k]["kind"] == "filled_pause":
        return "block", "before_filler"
    if k in restart_points:
        return "block", "before_restart"
    return "block", "inside_phrase"


def detect_events(
    words: list[WordDoc], pauses: list[Pause], thresholds: Thresholds
) -> list[EventDoc]:
    """All rules events, sorted, without ids."""
    t = _Transcript(words, pauses)
    restarts = _restarts_at_cutoffs(t, thresholds)
    repetitions = _repetitions(t)
    taken = {i for e in restarts + repetitions for i in range(e["word_start"], e["word_end"])}
    restarts += _abandoned_phrases(t, taken, thresholds)
    lexical = _lexical_fillers(t)

    restart_points = {e["word_start"] for e in restarts + repetitions} | {
        e["repair_word"] for e in restarts + repetitions if e["repair_word"] is not None
    }
    filler_words = {i for e in lexical for i in range(e["word_start"], e["word_end"])}
    pause_events = []
    for pause in pauses:
        type_, reason = _classify_pause(t, pause, restart_points, filler_words)
        pause_events.append(
            event(type_, pause.start, pause.end, pause.before, pause.before, reason=reason)
        )

    events = _filled_pauses(words) + lexical + restarts + repetitions + pause_events
    return sorted(events, key=sort_key)
