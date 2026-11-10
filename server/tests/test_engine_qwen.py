from speakup.stt.qwen import QwenASREngine, parse_output, words_from_alignment


def test_qwen_words_are_aligned_units_with_punctuation_attached():
    text = "嗯，那个，我我觉得 Postgres 的迁移还要两天。"
    items = [
        ("嗯", 0.0, 0.24),
        ("那", 0.48, 0.72),
        ("个", 0.72, 0.96),
        ("我", 1.36, 1.36),
        ("我", 1.36, 1.6),
        ("觉", 1.6, 1.84),
        ("得", 1.84, 2.0),
        ("Postgres", 2.16, 2.64),
        ("的", 3.04, 3.12),
        ("迁", 3.12, 3.44),
        ("移", 3.44, 3.76),
        ("还", 3.76, 4.0),
        ("要", 4.0, 4.16),
        ("两", 4.16, 4.4),
        ("天", 4.4, 4.72),
    ]
    transcript = parse_output("qwen3-asr-1.7b", text, items, 5.0)
    assert [w.text for w in transcript.words] == [
        "嗯，",
        "那",
        "个，",
        "我",
        "我",
        "觉",
        "得",
        "Postgres",
        "的",
        "迁",
        "移",
        "还",
        "要",
        "两",
        "天。",
    ]
    assert (transcript.words[7].start, transcript.words[7].end) == (2.16, 2.64)
    assert all(w.confidence is None for w in transcript.words)
    assert transcript.text == text
    assert transcript.engine == "qwen3-asr-1.7b"
    assert transcript.raw["items"][0] == ["嗯", 0.0, 0.24]


def test_qwen_joins_hyphenated_latin_units_and_keeps_unmatched_units():
    text = "我们的A-P-I，呃"
    items = [
        ("我", 0.0, 0.2),
        ("们", 0.2, 0.4),
        ("的", 0.4, 0.5),
        ("A", 0.6, 0.7),
        ("P", 0.7, 0.8),
        ("I", 0.8, 0.9),
        ("额", 1.2, 1.5),
    ]
    words = words_from_alignment(text, items)
    assert [(w.text, w.start, w.end) for w in words] == [
        ("我", 0.0, 0.2),
        ("们", 0.2, 0.4),
        ("的", 0.4, 0.5),
        ("A-P-I，", 0.6, 0.9),
        ("额", 1.2, 1.5),
    ]


def test_qwen_engine_names_its_install_command():
    engine = QwenASREngine("1.7B")
    assert engine.name == "qwen3-asr-1.7b"
    problem = engine.missing_config()
    assert problem is None or "uv sync --extra qwen" in problem
