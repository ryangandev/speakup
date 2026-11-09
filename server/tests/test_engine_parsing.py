import math

import httpx

from speakup.stt import assemblyai, elevenlabs
from speakup.stt.apple import parse_output


def test_scribe_keeps_words_and_drops_spacing_and_events():
    body = {
        "language_code": "en",
        "text": "Um, hello (laughter)",
        "words": [
            {"text": "Um,", "start": 0.0, "end": 0.3, "type": "word", "logprob": 0.0},
            {"text": " ", "start": 0.3, "end": 0.4, "type": "spacing", "logprob": 0.0},
            {"text": "hello", "start": 0.4, "end": 0.8, "type": "word", "logprob": math.log(0.5)},
            {"text": "(laughter)", "start": 0.8, "end": 1.2, "type": "audio_event", "logprob": 0},
        ],
    }
    transcript = elevenlabs.parse_response(body, 1.2)
    assert [(w.text, w.start, w.end) for w in transcript.words] == [
        ("Um,", 0.0, 0.3),
        ("hello", 0.4, 0.8),
    ]
    assert transcript.words[1].confidence == 0.5


def test_scribe_request_is_verbatim(tmp_path, monkeypatch):
    monkeypatch.setenv("ELEVENLABS_API_KEY", "test-key")
    seen = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["headers"] = request.headers
        seen["body"] = request.read()
        return httpx.Response(200, json={"text": "", "words": []})

    wav = tmp_path / "a.wav"
    wav.write_bytes(b"RIFF")
    engine = elevenlabs.ScribeEngine(client=httpx.Client(transport=httpx.MockTransport(handler)))
    engine.transcribe(wav, 1.0)
    assert seen["headers"]["xi-api-key"] == "test-key"
    body = seen["body"].decode(errors="replace")
    for field, value in [
        ("model_id", "scribe_v2"),
        ("no_verbatim", "false"),
        ("timestamps_granularity", "word"),
    ]:
        assert f'name="{field}"\r\n\r\n{value}' in body


def test_assemblyai_uploads_prompts_and_polls(tmp_path, monkeypatch):
    monkeypatch.setenv("ASSEMBLYAI_API_KEY", "test-key")
    polls = iter(["processing", "completed"])
    requests = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        path = request.url.path
        if path == "/v2/upload":
            return httpx.Response(200, json={"upload_url": "https://cdn/x"})
        if path == "/v2/transcript":
            return httpx.Response(200, json={"id": "t1"})
        status = next(polls)
        body = {
            "status": status,
            "text": "um yes",
            "words": [{"text": "um", "start": 100, "end": 400, "confidence": 0.9}],
        }
        return httpx.Response(200, json=body)

    wav = tmp_path / "a.wav"
    wav.write_bytes(b"RIFF")
    client = httpx.Client(transport=httpx.MockTransport(handler))
    engine = assemblyai.AssemblyAIEngine(client=client, poll_seconds=0)
    transcript = engine.transcribe(wav, 1.0)
    job = requests[1].read().decode()
    assert '"universal-3-5-pro"' in job and "filler" in job
    assert [(w.text, w.start, w.end) for w in transcript.words] == [("um", 0.1, 0.4)]


def test_apple_runs_split_into_words_sharing_times():
    body = {"text": "So the", "runs": [{"text": "So the", "start": 0.4, "end": 0.9}]}
    transcript = parse_output(body, 1.0)
    assert [(w.text, w.start) for w in transcript.words] == [("So", 0.4), ("the", 0.4)]
