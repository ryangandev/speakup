"""Settings, the startup command, default wiring and the real audio conversion."""

from __future__ import annotations

import io
import shutil
import wave

import pytest
import soundfile
from support import TAKE1_ID, build_env

from speakup import config
from speakup.api import cli, defaults
from speakup.audio import to_wav16k


@pytest.fixture
def clean_settings(monkeypatch):
    for name in (
        "SPEAKUP_API_TOKEN",
        "SPEAKUP_DATA_DIR",
        "SPEAKUP_STT_ENGINE",
        "SPEAKUP_COACH_MODEL",
        "SPEAKUP_PORT",
    ):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setattr(config, "_FILE_VALUES", {})


def test_settings_defaults(clean_settings):
    settings = config.server_settings()
    assert settings.api_token is None
    assert settings.port == 8765
    assert settings.stt_engine == "crisperwhisper"
    assert settings.coach_model == "claude-opus-5-5"
    assert settings.data_dir == config.REPO_DIR / "data" / "server"


def test_settings_from_the_environment(clean_settings, monkeypatch, tmp_path):
    monkeypatch.setenv("SPEAKUP_API_TOKEN", "abc")
    monkeypatch.setenv("SPEAKUP_PORT", "18765")
    monkeypatch.setenv("SPEAKUP_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("SPEAKUP_STT_ENGINE", "scribe")
    settings = config.server_settings()
    assert (settings.api_token, settings.port, settings.data_dir) == ("abc", 18765, tmp_path)
    assert settings.stt_engine == "scribe"


def test_a_relative_data_dir_is_relative_to_the_repository(clean_settings, monkeypatch):
    monkeypatch.setenv("SPEAKUP_DATA_DIR", "somewhere/else")
    assert config.server_settings().data_dir == config.REPO_DIR / "somewhere" / "else"


@pytest.mark.parametrize("port", ["abc", "0", "70000"])
def test_a_bad_port_is_refused(clean_settings, monkeypatch, port):
    monkeypatch.setenv("SPEAKUP_PORT", port)
    with pytest.raises(ValueError, match="SPEAKUP_PORT"):
        config.server_settings()


def test_the_command_refuses_to_start_without_a_token(clean_settings, capsys):
    assert cli.main() == 2
    assert "SPEAKUP_API_TOKEN" in capsys.readouterr().err


def test_the_command_says_clearly_when_a_module_is_missing(clean_settings, monkeypatch, capsys):
    monkeypatch.setenv("SPEAKUP_API_TOKEN", "abc")

    def missing(name):
        raise ImportError(f"No module named {name!r}")

    monkeypatch.setattr(defaults.importlib, "import_module", missing)
    assert cli.main() == 2
    assert "speakup.analysis" in capsys.readouterr().err


def test_the_command_refuses_a_bad_port(clean_settings, monkeypatch, capsys):
    monkeypatch.setenv("SPEAKUP_API_TOKEN", "abc")
    monkeypatch.setenv("SPEAKUP_PORT", "abc")
    assert cli.main() == 2
    assert "SPEAKUP_PORT" in capsys.readouterr().err


def test_the_default_engine_name_is_an_alias_for_crisper_large(clean_settings):
    engine = defaults.default_engine(config.server_settings())
    assert engine.name == "crisper-large"


def test_an_unknown_engine_lists_the_choices(clean_settings, monkeypatch):
    monkeypatch.setenv("SPEAKUP_STT_ENGINE", "whisper")
    with pytest.raises(RuntimeError, match="crisper-turbo"):
        defaults.default_engine(config.server_settings())


# -- the real conversion ----------------------------------------------------------------------

needs_converter = pytest.mark.skipif(
    not (shutil.which("ffmpeg") or shutil.which("afconvert")),
    reason="neither ffmpeg nor afconvert is installed",
)


def stereo_48k_wav(seconds: float = 0.5) -> bytes:
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as out:
        out.setnchannels(2)
        out.setsampwidth(2)
        out.setframerate(48_000)
        out.writeframes(b"\x01\x00\x02\x00" * int(seconds * 48_000))
    return buffer.getvalue()


@needs_converter
def test_the_pipeline_converts_what_the_phone_sends(tmp_path):
    env = build_env(tmp_path / "data", convert=to_wav16k)
    env.seed()
    assert env.upload(TAKE1_ID, attempt=1, audio=stereo_48k_wav()).status_code == 201
    env.run()
    assert env.take(TAKE1_ID)["status"] == "done"
    path, seconds = env.engine.calls[0]
    info = soundfile.info(str(path))
    assert (info.samplerate, info.channels) == (16_000, 1)
    assert seconds == pytest.approx(0.5, abs=0.05)
    original = env.data_dir / "takes" / TAKE1_ID / "original.wav"
    assert soundfile.info(str(original)).samplerate == 48_000  # the upload is kept unchanged


@needs_converter
def test_a_wav_header_with_a_broken_body_is_audio_invalid(tmp_path):
    env = build_env(tmp_path / "data", convert=to_wav16k)
    env.seed()
    broken = b"RIFF\x24\x00\x00\x00WAVEjunkjunkjunkjunk" + b"\xff" * 64
    assert env.upload(TAKE1_ID, attempt=1, audio=broken).status_code == 201
    env.run()
    take = env.take(TAKE1_ID)
    assert take["status"] == "failed"
    assert take["error"]["code"] == "audio_invalid"
    assert env.engine.calls == []
