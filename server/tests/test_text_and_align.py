from speakup.bakeoff.align import align
from speakup.stt import Word
from speakup.text import Token, tokens_from_text, tokens_from_words


def texts(tokens: list[Token]) -> list[str]:
    return [str(t) for t in tokens]


def test_engine_styles_normalize_to_the_same_tokens():
    crisper = tokens_from_text("[UM] so we we need to, to reschedule the th- thursday [laughter]")
    scribe = tokens_from_text("Um, so we we need to, to reschedule the th\N{EM DASH} Thursday.")
    assert texts(crisper) == texts(scribe)
    assert texts(crisper) == [
        "um",
        "so",
        "we",
        "we",
        "need",
        "to",
        "to",
        "reschedule",
        "the",
        "th-",
        "thursday",
    ]


def test_filler_spellings_map_to_one_form():
    assert texts(tokens_from_text("Umm, uhh... erm (uh) hmm Mm")) == [
        "um",
        "uh",
        "um",
        "uh",
        "hmm",
        "hmm",
    ]


def test_internal_hyphens_split_and_comments_are_ignored():
    gold = "# DRAFT: delete me\n# a comment\nA follow-up on the e-mail."
    assert texts(tokens_from_text(gold)) == ["a", "follow", "up", "on", "the", "e", "mail"]


def test_timed_words_keep_times_when_split():
    tokens = tokens_from_words([Word("follow-up", 1.0, 1.5), Word("[laughter]", 1.5, 2.0)])
    assert [(t.text, t.start, t.end) for t in tokens] == [("follow", 1.0, 1.5), ("up", 1.0, 1.5)]


def test_alignment_marks_missed_filler_and_cutoff_variants():
    gold = tokens_from_text("um we need th- the database")
    hyp = tokens_from_text("we need the- the database")
    pairs = align(gold, hyp)
    assert [p.op for p in pairs] == ["del", "match", "match", "match", "match", "match"]


def test_alignment_handles_insertions_and_substitutions():
    gold = tokens_from_text("ship it friday")
    hyp = tokens_from_text("uh ship it monday")
    assert [p.op for p in align(gold, hyp)] == ["ins", "match", "match", "sub"]
