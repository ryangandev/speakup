"""Numbered schema migrations, applied at startup.

Version 1 is the DDL in docs/architecture.md#storage, verbatim. Add a new tuple for every schema
change and never edit an applied one.
"""

from __future__ import annotations

# The DDL is kept verbatim from the doc, long lines included.
# ruff: noqa: E501

MIGRATION_1 = """
CREATE TABLE schema_migrations (
  version INTEGER PRIMARY KEY,
  applied_at TEXT NOT NULL
);

CREATE TABLE sessions (
  id TEXT PRIMARY KEY,
  mode TEXT NOT NULL CHECK (mode IN ('home', 'driving')),
  started_at TEXT NOT NULL,
  ended_at TEXT,
  nervousness_before INTEGER CHECK (nervousness_before BETWEEN 1 AND 5),
  nervousness_after INTEGER CHECK (nervousness_after BETWEEN 1 AND 5),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX sessions_started ON sessions (started_at);

CREATE TABLE prompts (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES sessions (id),
  kind TEXT NOT NULL CHECK (kind IN ('prepared', 'impromptu')),
  text TEXT NOT NULL,
  notes TEXT,
  category TEXT,
  target_seconds INTEGER NOT NULL,
  question_source TEXT NOT NULL CHECK (question_source IN ('typed', 'claude', 'bank')),
  created_at TEXT NOT NULL
);
CREATE INDEX prompts_session ON prompts (session_id, created_at);

CREATE TABLE takes (
  id TEXT PRIMARY KEY,
  prompt_id TEXT NOT NULL REFERENCES prompts (id),
  attempt INTEGER NOT NULL,
  recorded_at TEXT NOT NULL,
  duration_s REAL NOT NULL,
  mic_route TEXT,
  audio_sha256 TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('uploaded', 'transcribing', 'analyzing', 'coaching', 'done', 'failed')),
  status_changed_at TEXT NOT NULL,
  coaching_status TEXT NOT NULL CHECK (coaching_status IN ('pending', 'done', 'unavailable', 'failed')),
  previous_take_id TEXT REFERENCES takes (id),
  error_code TEXT,
  error_message TEXT,
  stage_failures INTEGER NOT NULL DEFAULT 0,
  transcript_id TEXT REFERENCES transcripts (id),
  analysis_id TEXT REFERENCES analyses (id),
  coaching_id TEXT REFERENCES coaching_reports (id),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (prompt_id, attempt)
);
CREATE INDEX takes_queue ON takes (status, recorded_at);

-- Stage outputs keep every run; takes.*_id points at the current one.
CREATE TABLE transcripts (
  id TEXT PRIMARY KEY,
  take_id TEXT NOT NULL REFERENCES takes (id),
  engine TEXT NOT NULL,
  created_at TEXT NOT NULL,
  json TEXT NOT NULL            -- speakup.stt.Transcript as saved by Transcript.save
);

CREATE TABLE analyses (
  id TEXT PRIMARY KEY,
  take_id TEXT NOT NULL REFERENCES takes (id),
  transcript_id TEXT NOT NULL REFERENCES transcripts (id),
  schema_version TEXT NOT NULL,
  created_at TEXT NOT NULL,
  stage_json TEXT NOT NULL,     -- analyze() output, rules only
  final_json TEXT NOT NULL      -- finalize(stage, coaching); rewritten when coaching changes
);

CREATE TABLE coaching_reports (
  id TEXT PRIMARY KEY,
  take_id TEXT NOT NULL REFERENCES takes (id),
  analysis_id TEXT NOT NULL REFERENCES analyses (id),
  model TEXT NOT NULL,
  rubric_version TEXT NOT NULL,
  prompt_version TEXT NOT NULL,
  created_at TEXT NOT NULL,
  json TEXT NOT NULL,           -- the coaching report
  usage_json TEXT               -- API token usage, for cost tracking
);
"""

# Set while the worker has a take's stage in hand, cleared when the take finishes or fails.
# A restart only counts a stage as interrupted if this is set.
MIGRATION_2 = """
ALTER TABLE takes ADD COLUMN stage_started_at TEXT;
"""

MIGRATIONS: list[tuple[int, str]] = [(1, MIGRATION_1), (2, MIGRATION_2)]
