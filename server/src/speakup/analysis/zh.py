"""Mandarin (`zh`) rules: word kinds, repetitions, lexical filler candidates and clause starts.

A Mandarin engine writes one token per character (sometimes per word) with no spaces, so these
rules work on spoken units (`speakup.text.zh_units`: each Han character, each Latin-script word)
and only mark spans that start and end on token boundaries. Everything timing-based (pauses,
blocks, cut-off restarts, metrics) is shared with English. Like the English rules, each one
prefers missing an event to inventing one. See docs/architecture.md#events.
"""

from __future__ import annotations

from dataclasses import dataclass

from speakup.analysis.events import EventDoc, _setoff_after, _setoff_before, _Transcript, event
from speakup.analysis.words import (
    WordDoc,
    _confidence,
    ends_clause,
    ends_sentence,
    final_punctuation,
)
from speakup.stt import Word
from speakup.text import (
    FILLED_PAUSES,
    ZH_FILLED_PAUSES,
    ZH_FILLED_PAUSES_STANDALONE,
    ZH_INTERJECTIONS,
    is_cjk,
    tokens_from_words,
    zh_units,
)

# A hesitation sound counts as set off from a neighbour by a word gap this long, the same 250 ms
# as Thresholds.min_pause_s.
STANDALONE_GAP_S = 0.25

# Cut-off restarts reach back this many times further than in English, since a unit is a
# character rather than a word.
RESTART_LOOKBACK_FACTOR = 2

# Lexical filler candidates, longest first so 怎么说 wins over nothing shorter.
LEXICAL_CANDIDATES = ("怎么说", "那个", "这个", "就是", "然后", "其实", "反正", "对")
# Demonstratives and 就是 are mostly grammatical ("这个方案", "问题就是"): a candidate only when
# set off on at least one side by a silence, punctuation or a filled pause. A sentence start alone
# does not count, since "这个方案很好" opens sentences all the time.
_SET_OFF_ONE_SIDE = {"那个", "这个", "就是"}
# 对 is part of many words (对于, 不对, 对比): a candidate only when it stands alone.
_STANDALONE = {"对"}

# Reduplication: these characters and words double on purpose (看看, 试试, 谢谢, 常常, 慢慢,
# 刚刚, 人人, 天天, 研究研究), so a double counts as a repetition only with a hesitation between.
ZH_REDUPLICATIONS = set(
    "看试想听说等聊问走谈找查改写读学玩坐尝比算帮讲弄搞动跑测用谢哥姐妹弟爸妈爷奶叔宝星"
    "哈嘻呵嘿拜常慢刚好往渐稍偏明默纷仅天人个家年处事样次步时刻匆悄轻静紧早远久多少大小"
    "高长满足白偷暗牢深淡浅细微重稳快恰统通频连屡每隐历区堂一对是不"
) | {
    "研究", "讨论", "考虑", "商量", "了解", "学习", "休息", "整理", "准备", "检查", "介绍",
    "收拾", "打听", "活动", "锻炼", "体验", "尝试", "练习", "交流", "沟通", "比较", "分析",
}  # fmt: skip
# Characters that stutter but do not double inside ordinary words. In a transcript of one token
# per character, "学生生活" (学生 then 生活) looks like a doubled 生, so a doubled character
# without a hesitation between counts only when it is one of these.
ZH_STUTTER_CHARS = set("我你他她它这那就把被和跟也都还但很让给从而")

# Words that open a clause; a pause before one is a boundary, not a block.
ZH_CLAUSE_STARTERS = (
    "但是", "但", "所以", "因为", "而且", "如果", "然后", "虽然", "不过", "另外", "首先",
    "其次", "最后", "第一", "第二", "第三", "可是", "因此", "并且", "或者", "还有", "那么",
    "比如", "例如", "总之", "其实", "同时", "接着", "于是",
)  # fmt: skip
_LATIN_CLAUSE_STARTERS = {"and", "but", "or", "so", "because", "if", "when"}
# Latin-script words in a Mandarin take that are often doubled on purpose ("yes yes").
_LATIN_DELIBERATE_DOUBLES = {
    "had",
    "that",
    "is",
    "very",
    "really",
    "bye",
    "no",
    "yes",
    "yeah",
    "ha",
}


# --- Words -----------------------------------------------------------------------------------


def _kind(norm_tokens: list[str]) -> str:
    if not norm_tokens:
        return "non_speech"
    if len(norm_tokens) == 1:
        token = norm_tokens[0]
        if token in FILLED_PAUSES.values():
            return "filled_pause"
        if is_cjk(token) and set(token) <= ZH_FILLED_PAUSES:
            return "filled_pause"
    return "word"


def _hesitation_sound(norm: str) -> str | None:
    """`interjection` (啊, 哦, 噢), `standalone` (额, 唔), or None."""
    if not norm or not is_cjk(norm):
        return None
    if set(norm) <= ZH_INTERJECTIONS:
        return "interjection"
    if set(norm) <= ZH_FILLED_PAUSES_STANDALONE:
        return "standalone"
    return None


def zh_word_docs(words: list[Word]) -> list[WordDoc]:
    """The `words` list for a Mandarin take.

    嗯 and 呃 are always filled pauses. 啊, 哦 and 噢 are filled pauses only when not attached to
    the word before (the start of the take, after punctuation or a filled pause, or after a
    word gap of 250 ms or more); right after a word they are sentence-final particles (好啊,
    是哦). 额 and 唔 also occur inside words (金额), so they must be set off on both sides.
    """
    docs: list[WordDoc] = []
    for i, word in enumerate(words):
        tokens = tokens_from_words([word], "zh")
        texts = [t.text for t in tokens]
        docs.append(
            {
                "i": i,
                "text": word.text,
                "norm": " ".join(texts),
                "start": float(word.start),
                "end": float(word.end),
                "confidence": _confidence(word.confidence),
                "kind": _kind(texts),
                "cutoff": bool(tokens) and tokens[-1].cutoff,
            }
        )

    spoken = [d for d in docs if d["kind"] != "non_speech"]
    for n, doc in enumerate(spoken):
        sound = _hesitation_sound(doc["norm"]) if doc["kind"] == "word" else None
        if sound is None or doc["cutoff"]:
            continue
        prev = spoken[n - 1] if n > 0 else None
        nxt = spoken[n + 1] if n + 1 < len(spoken) else None
        before = (
            prev is None
            or prev["kind"] == "filled_pause"
            or final_punctuation(prev) != ""
            or round(doc["start"] - prev["end"], 3) >= STANDALONE_GAP_S
        )
        after = (
            nxt is None
            or nxt["kind"] == "filled_pause"
            or final_punctuation(doc) != ""
            or round(nxt["start"] - doc["end"], 3) >= STANDALONE_GAP_S
        )
        if before and (sound == "interjection" or after):
            doc["kind"] = "filled_pause"
    return docs


# --- Units -----------------------------------------------------------------------------------


@dataclass(frozen=True)
class _Unit:
    text: str
    word: int  # index in `words`
    first: bool  # the first unit of its word
    last: bool  # the last unit of its word


def _units(t: _Transcript) -> list[_Unit]:
    """The content words' spoken units in order: filled pauses and sounds are skipped."""
    out = []
    for i in t.content:
        parts = zh_units(t.norm(i))
        out.extend(_Unit(text, i, k == 0, k == len(parts) - 1) for k, text in enumerate(parts))
    return out


def _aligned(span: list[_Unit]) -> bool:
    return bool(span) and span[0].first and span[-1].last


# --- Repetitions -----------------------------------------------------------------------------


def _deliberate_double(t: _Transcript, copy: list[_Unit], repeat: list[_Unit]) -> bool:
    """Whether a double is ordinary speech: a reduplication, or two words that happen to share
    a character. Either way it is a repetition only with a hesitation between the copies."""
    if t.hesitation_between(copy[-1].word, repeat[0].word):
        return False
    text = "".join(u.text for u in copy)
    if len(copy) == 1 and not is_cjk(text):
        return text in _LATIN_DELIBERATE_DOUBLES
    if len(copy) == 1:
        return text in ZH_REDUPLICATIONS or text not in ZH_STUTTER_CHARS
    # 研究研究, and 一个一个 ("one by one").
    return text in ZH_REDUPLICATIONS or (len(copy) == 2 and text.startswith("一"))


def repetitions(t: _Transcript) -> list[EventDoc]:
    """A character, word or phrase of up to four units said again right away: 我我, 就是就是,
    这个这个. Filled pauses between the copies do not break a repetition. `reason` is `word` for
    one token or a two-character word, `phrase` for anything longer."""
    events = []
    words = t.words
    units = _units(t)
    texts = [u.text for u in units]
    k = 0
    while k < len(units):
        for n in (4, 3, 2, 1):
            if k + 2 * n > len(units) or texts[k : k + n] != texts[k + n : k + 2 * n]:
                continue
            copy, repeat = units[k : k + n], units[k + n : k + 2 * n]
            if not (_aligned(copy) and _aligned(repeat)):
                continue
            if any(words[u.word]["cutoff"] for u in copy + repeat):
                continue
            if ends_sentence(words[copy[-1].word]) or _deliberate_double(t, copy, repeat):
                continue
            copies = 1
            while k + (copies + 2) * n <= len(units):
                more = units[k + (copies + 1) * n : k + (copies + 2) * n]
                if [u.text for u in more] != texts[k : k + n] or not _aligned(more):
                    break
                if any(words[u.word]["cutoff"] for u in more):
                    break
                copies += 1
            last = units[k + (copies + 1) * n - 1].word
            one_word = n == 1 or (n == 2 and is_cjk("".join(texts[k : k + n])))
            events.append(
                event(
                    "repetition",
                    words[copy[0].word]["start"],
                    words[last]["end"],
                    copy[0].word,
                    last + 1,
                    reason="word" if one_word else "phrase",
                    repair_word=repeat[0].word,
                )
            )
            k += copies * n
            break
        else:
            k += 1
    return events


# --- Lexical filler candidates ---------------------------------------------------------------


def lexical_fillers(t: _Transcript) -> list[EventDoc]:
    """Lexical filler candidates (那个, 这个, 就是, 然后, 对, 其实, 反正, 怎么说) as spans of whole
    tokens, with the same cautious rules estimate as English: a filler only when set off on
    both sides by a silence, or by punctuation on both sides. Coaching judges each in context."""
    events = []
    words = t.words
    units = _units(t)
    k = 0
    while k < len(units):
        found = None
        if units[k].first:
            for candidate in LEXICAL_CANDIDATES:
                span = units[k : k + len(candidate)]
                if "".join(u.text for u in span) != candidate or not span[-1].last:
                    continue
                # Contiguous tokens: no filled pause or sound inside the span.
                if any(b.word - a.word > 1 for a, b in zip(span, span[1:], strict=False)):
                    continue
                if any(words[u.word]["cutoff"] for u in span):
                    continue
                found = (candidate, span)
                break
        if found is None:
            k += 1
            continue
        candidate, span = found
        k += len(span)
        first, last = span[0].word, span[-1].word
        before, after = _setoff_before(t, first), _setoff_after(t, last)
        if candidate in _STANDALONE and (before is None or after is None):
            continue
        marked = {"silence", "punctuation", "filled"}
        if candidate in _SET_OFF_ONE_SIDE and before not in marked and after not in marked:
            continue
        is_filler = (
            before is not None
            and after is not None
            and ("silence" in (before, after) or before == after == "punctuation")
        )
        events.append(
            event(
                "lexical_filler",
                words[first]["start"],
                words[last]["end"],
                first,
                last + 1,
                is_filler=is_filler,
                filler_resolution="rules",
            )
        )
    return events


# --- Pause boundaries ------------------------------------------------------------------------


def starts_clause(t: _Transcript, i: int) -> bool:
    """Whether content word i opens a clause: 但是, 所以, 因为, 然后 and the like."""
    if t.words[i]["cutoff"]:
        return False
    position = t.position.get(i)
    if position is None:
        return False
    head: list[str] = []
    for j in t.content[position : position + 4]:
        head.extend(zh_units(t.norm(j)))
    if not head:
        return False
    if not is_cjk(head[0]):
        return head[0] in _LATIN_CLAUSE_STARTERS
    text = "".join(u for u in head if is_cjk(u))
    return text.startswith(ZH_CLAUSE_STARTERS)


def boundary(
    t: _Transcript, prev: int | None, nxt: int | None, filler_words: set[int]
) -> str | None:
    """`sentence` or `clause` when the gap between content words prev and nxt is a boundary.
    Capital letters mean nothing in Chinese, so only punctuation and clause starters count."""
    if prev is None or nxt is None or ends_sentence(t.words[prev]):
        return "sentence"
    if ends_clause(t.words[prev]) and prev not in filler_words:
        return "clause"
    if starts_clause(t, nxt):
        return "clause"
    return None
