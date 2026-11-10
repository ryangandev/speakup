"""Mandarin analysis: normalization, word kinds, fillers, repetitions, restarts, pauses and the
per-character metrics. Scripts are written as an engine emits them: one token per character,
punctuation attached, Latin-script words whole."""

from __future__ import annotations

import pytest
from analysis_helpers import analyze_script, analyze_zh, events_of, spans

from speakup.analysis import compare_metrics
from speakup.stt import Word
from speakup.text import join_words, tokens_from_words, zh_units


@pytest.mark.parametrize(
    ("text", "tokens"),
    [
        ("我", ["我"]),
        ("我们，", ["我们"]),
        ("好。", ["好"]),
        ("“对”", ["对"]),
        ("？", []),
        ("（笑声）", []),
        ("[laughter]", []),
        ("嗯嗯", ["嗯嗯"]),
        ("用API", ["用", "api"]),
        ("Postgres，", ["postgres"]),
        ("Um,", ["um"]),
    ],
)
def test_normalization_keeps_characters_and_strips_punctuation(text, tokens):
    assert [t.text for t in tokens_from_words([Word(text, 0, 1)], "zh")] == tokens


def test_a_token_ending_in_a_dash_is_cut_off():
    (token,) = tokens_from_words([Word("需要\N{EM DASH}\N{EM DASH}", 0, 1)], "zh")
    assert (token.text, token.cutoff) == ("需要", True)


def test_units_and_running_text():
    assert zh_units("我们") == ["我", "们"]
    assert zh_units("用 api") == ["用", "api"]
    assert join_words(["我", "们", "用", "AWS", "S3", "，", "好"], "zh") == "我们用AWS S3，好"
    assert join_words(["We", "chose"]) == "We chose"


def _kinds(doc):
    return [(w["text"], w["kind"]) for w in doc["words"] if w["kind"] != "word"]


def test_filled_pauses():
    doc = analyze_zh("嗯 我 们 |0.3| 呃 选 了 Postgres， 嗯嗯 好 了。")
    assert _kinds(doc) == [("嗯", "filled_pause"), ("呃", "filled_pause"), ("嗯嗯", "filled_pause")]
    assert spans(doc, "filled_pause") == ["嗯", "呃", "嗯嗯"]


def test_a_particle_after_a_word_is_not_a_filled_pause():
    doc = analyze_zh("这 个 问 题 啊， 很 好 啊。 是 哦。")
    assert _kinds(doc) == []


def test_a_standalone_interjection_is_a_filled_pause():
    doc = analyze_zh("我 觉 得 |0.4| 啊 这 个 方 案 好。 啊， 我 们 选 它。 哦 |0.3| 对 了")
    assert spans(doc, "filled_pause") == ["啊", "啊，", "哦"]


def test_e_inside_a_word_is_not_a_filled_pause_but_standalone_is():
    doc = analyze_zh("金 额 很 大。 额 |0.5| 我 们 再 看。 额 外 的 钱。")
    assert spans(doc, "filled_pause") == ["额"]
    assert doc["words"][4]["kind"] == "filled_pause"


def test_lexical_candidates_cover_every_token_of_the_span():
    doc = analyze_zh("第 一， 那 个 |0.5| 账 单 很 复 杂。 然 后 我 们 其 实 改 了， 反 正 也 快。")
    events = events_of(doc, "lexical_filler")
    assert spans(doc, "lexical_filler") == ["那个", "然后", "其实", "反正"]
    first = events[0]
    assert first["word_end"] - first["word_start"] == 2
    assert first["is_filler"] is True  # a comma before, a silence after
    assert [e["is_filler"] for e in events[1:]] == [False, False, False]


def test_a_candidate_written_as_one_token_is_one_word():
    doc = analyze_zh("我 们 |0.4| 那个 |0.4| 选 了 它。")
    (event,) = events_of(doc, "lexical_filler")
    assert (event["word_end"] - event["word_start"], event["is_filler"]) == (1, True)


@pytest.mark.parametrize(
    "script",
    [
        "这 个 方 案 很 好。",  # a demonstrative before a noun
        "我 们 对 于 这 件 事 很 清 楚。",  # 对 inside 对于
        "这 样 不 对 吧。",
        "问 题 就 是 成 本。",
        "我 们 那 |0.6| 嗯 个 方 案。",  # a filled pause inside the span
    ],
)
def test_grammatical_uses_are_not_candidates(script):
    assert events_of(analyze_zh(script), "lexical_filler") == []


def test_standalone_dui_and_set_off_zhege_are_candidates():
    doc = analyze_zh("对， 我 们 选 了 它。 这 个 |0.5| 很 难 说。 怎 么 说 呢， 还 行。")
    assert spans(doc, "lexical_filler") == ["对，", "这个", "怎么说"]


@pytest.mark.parametrize(
    ("script", "expected", "reason"),
    [
        ("我 我 觉 得 可 以。", "我我", "word"),
        ("我 们 就 是 就 是 想 快 一 点。", "就是就是", "word"),
        ("这 个 这 个 方 案 好。", "这个这个", "word"),
        ("我们 我们 选 了 它。", "我们我们", "word"),
        ("我 们 选 了 |0.4| 我 们 选 了 Postgres。", "我们选了我们选了", "phrase"),
        ("这 这 这 个 方 案。", "这这这", "word"),
        ("那 |0.5| 嗯 那 个 方 案。", "那嗯那", "word"),
        ("我 们 看 |0.6| 看 吧。", "看看", "word"),
        ("我 们 用 Postgres Postgres 好。", "PostgresPostgres", "word"),
    ],
)
def test_repetitions(script, expected, reason):
    doc = analyze_zh(script)
    assert spans(doc, "repetition") == [expected]
    assert events_of(doc, "repetition")[0]["reason"] == reason


@pytest.mark.parametrize(
    "script",
    [
        "我 们 看 看 再 说。",
        "试 试 这 个 办 法。",
        "谢 谢 大 家 的 帮 助。",
        "我 们 常 常 加 班。",
        "慢 慢 来 不 着 急。",
        "刚 刚 上 线 了 新 版。",
        "人 人 都 知 道。",
        "天 天 开 会 很 累。",
        "我 们 研 究 研 究 再 定。",
        "一 个 一 个 改。",
        "学 生 生 活 很 忙。",  # two words that share a character
        "这 是 公 司 司 机。",
        "对 对 对， 就 这 样。",
        "好。 好， 我 们 开 始。",  # across a sentence end
    ],
)
def test_reduplication_and_shared_characters_are_not_repetitions(script):
    assert events_of(analyze_zh(script), "repetition") == []


def test_three_copies_are_one_repetition():
    doc = analyze_zh("我 我 我 觉 得 行。")
    (event,) = events_of(doc, "repetition")
    assert (event["word_start"], event["word_end"], event["repair_word"]) == (0, 3, 1)


def test_cutoff_restart_reaches_back_to_the_repeated_start():
    doc = analyze_zh("我 们 需 要- 我 们 应 该 迁 移。")
    (event,) = events_of(doc, "restart")
    assert (event["reason"], event["word_start"], event["word_end"], event["repair_word"]) == (
        "cutoff",
        0,
        4,
        4,
    )


def test_blocks_and_boundary_pauses_follow_the_timing_rules():
    doc = analyze_zh(
        "第 二 个 原 因 是 |1.2| 团 队 熟 悉。 |0.8| 所 以 我 们 选 了 它， "
        "|0.6| 但 是 |0.3| 嗯 成 本 高。"
    )
    blocks = [(e["reason"], round(e["end"] - e["start"], 2)) for e in events_of(doc, "block")]
    assert blocks == [("inside_phrase", 1.2), ("before_filler", 0.5)]
    assert [e["reason"] for e in events_of(doc, "boundary_pause")] == ["sentence", "clause"]


def test_a_pause_before_a_clause_starter_is_a_boundary():
    doc = analyze_zh("我 们 选 了 Postgres |0.7| 因 为 团 队 熟 悉。")
    assert events_of(doc, "block") == []
    assert [e["reason"] for e in events_of(doc, "boundary_pause")] == ["clause"]


def test_a_short_gap_between_characters_is_no_pause():
    doc = analyze_zh("我 们 选 了 Postgres。", gap_s=0.02)
    assert [e for e in doc["events"] if e["type"] in ("block", "boundary_pause")] == []


def test_word_count_and_pace_are_per_character():
    # 10 characters (我们 as one token counts 2) plus 1 Latin word; the filled pause is excluded.
    doc = analyze_zh("我们 选 了 |0.3| 嗯 Postgres， 因 为 好 用 啊。", char_s=0.25, gap_s=0.0)
    metrics = doc["metrics"]
    assert doc["language"] == "zh"
    assert metrics["word_count"] == 10
    assert metrics["fillers"]["filled_pauses"] == 1
    assert metrics["fillers"]["per_100_words"] == 10.0
    assert metrics["pace"]["wpm_speaking"] == round(10 / metrics["speaking_s"] * 60, 1)


def test_english_takes_are_unchanged_by_default():
    doc = analyze_script("we chose um Postgres because because it works and the team knows it")
    assert doc["language"] == "en"
    assert doc["metrics"]["word_count"] == 12


def test_comparison_labels_say_characters_for_mandarin():
    a = analyze_zh("我 们 选 了 Postgres， 因 为 团 队 熟 悉。")
    b = analyze_zh("我 们 选 了 Postgres。")
    labels = {c["metric"]: (c["label"], c["unit"]) for c in compare_metrics(a, b)}
    assert labels["fillers_per_100_words"] == ("Fillers per 100 characters", "per 100 characters")
    assert labels["wpm_voiced"] == ("Pace", "characters per minute")
    english = analyze_script("we chose Postgres because the team knows it well")
    labels = {c["metric"]: c["unit"] for c in compare_metrics(english, english)}
    assert labels["wpm_voiced"] == "words per minute"
