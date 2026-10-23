from concurrent.futures import ThreadPoolExecutor
from threading import Event

import pytest
from io import BytesIO
from PIL import Image
from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app
from app.provider import MockProvider

with BytesIO() as stream, Image.new("RGB", (8, 4), "red") as image:
    image.save(stream, format="PNG")
    PNG = stream.getvalue()
AUTH = {"Authorization": "Bearer test-token"}
PAYLOAD = {"topic_ids": ["leaves-plants"], "count": 3}


@pytest.fixture
def settings(tmp_path):
    return Settings(_env_file=None, client_token="test-token", provider_mode="mock", database_path=tmp_path / "db.sqlite3")


@pytest.fixture
def client(settings):
    with TestClient(create_app(settings)) as client:
        yield client


def generate(client, key="generation", payload=None):
    return client.post("/api/v1/challenges/generate", headers=dict(AUTH, **{"Idempotency-Key": key}), json=PAYLOAD if payload is None else payload)


def verify(client, identifier, key="verification", image=PNG, content_type="image/png", filename="photo.png"):
    return client.post(f"/api/v1/challenges/{identifier}/verify", headers=dict(AUTH, **{"Idempotency-Key": key}), files={"photo": (filename, image, content_type)})


def test_health_is_public_and_request_id_is_returned(client):
    response = client.get("/health", headers={"X-Request-ID": "iphone-123"})
    assert response.json() == {"status": "ok"}
    assert response.headers["x-request-id"] == "iphone-123"


def test_topics_auth_and_error_envelope(client):
    response = client.get("/api/v1/topics")
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "unauthorized"
    assert response.json()["request_id"] == response.headers["x-request-id"]
    result = client.get("/api/v1/topics", headers=AUTH)
    assert len(result.json()["topics"]) == 9
    assert "difficulties" not in result.json()
    assert "difficulty" not in generate(client).json()["challenges"][0]


def test_generate_retrieve_and_replay(client):
    original = generate(client)
    assert original.status_code == 201
    assert original.json()["is_mock"] is True
    assert original.headers["idempotency-replayed"] == "false"
    challenges = original.json()["challenges"]
    assert len(challenges) == 3
    assert len({item["id"] for item in challenges}) == 3
    found = client.get(f'/api/v1/challenges/{challenges[0]["id"]}', headers=AUTH)
    assert found.json() == challenges[0]
    assert "criteria" not in found.json()
    replay = generate(client)
    assert replay.json() == original.json()
    assert replay.headers["idempotency-replayed"] == "true"
    assert replay.headers["x-request-id"] != original.headers["x-request-id"]


def test_changed_generation_payload_conflicts(client):
    generate(client)
    changed = generate(client, payload=dict(PAYLOAD, count=2))
    assert changed.status_code == 409
    assert changed.json()["error"]["code"] == "idempotency_conflict"


@pytest.mark.parametrize("payload", [dict(PAYLOAD, topic_ids=["unknown"]), dict(PAYLOAD, count=6), dict(PAYLOAD, topic_ids=["leaves-plants", "leaves-plants"]), dict(PAYLOAD, count=True)])
def test_invalid_generation(client, payload):
    assert generate(client, payload=payload).status_code == 422


def test_key_required(client):
    response = client.post("/api/v1/challenges/generate", headers=AUTH, json=PAYLOAD)
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "validation_error"


def test_difficulty_is_no_longer_accepted(client):
    assert generate(client, payload=dict(PAYLOAD, difficulty="easy")).status_code == 422


def test_regeneration_retains_old_assignment_and_replays(client):
    identifier = generate(client).json()["challenges"][0]["id"]
    url = f"/api/v1/challenges/{identifier}/regenerate"
    headers = dict(AUTH, **{"Idempotency-Key": "replacement"})
    replacement = client.post(url, headers=headers, json={"reason": "unsafe"})
    assert replacement.status_code == 201
    assert replacement.json()["replaces_id"] == identifier
    old = client.get(f"/api/v1/challenges/{identifier}", headers=AUTH).json()
    assert old["status"] == "replaced"
    assert old["replaced_by_id"] == replacement.json()["id"]
    assert client.post(url, headers=headers, json={"reason": "unsafe"}).json() == replacement.json()
    assert verify(client, identifier).status_code == 409


def test_verification_mock_and_image_fingerprint_replay(client):
    identifier = generate(client).json()["challenges"][0]["id"]
    original = verify(client, identifier)
    assert original.status_code == 200
    assert original.json()["status"] == "uncertain"
    assert original.json()["is_mock"] is True
    # Filenames and multipart boundaries are not part of the logical input.
    replay = verify(client, identifier, filename="renamed.png")
    assert replay.json() == original.json()
    assert replay.headers["idempotency-replayed"] == "true"
    assert verify(client, identifier, image=PNG + b"changed").status_code == 409
    assert verify(client, identifier, key="another-attempt").json()["attempt_id"] != original.json()["attempt_id"]


@pytest.mark.parametrize("image, content_type, status", [(b"", "image/png", 422), (b"not a photo", "image/png", 415), (PNG, "image/heic", 415)])
def test_upload_validation(client, image, content_type, status):
    identifier = generate(client).json()["challenges"][0]["id"]
    assert verify(client, identifier, image=image, content_type=content_type).status_code == status


def test_upload_size_bounds_before_and_after_multipart(settings):
    settings.max_upload_bytes = 100
    settings.max_request_bytes = 1024
    with TestClient(create_app(settings)) as client:
        identifier = generate(client).json()["challenges"][0]["id"]
        assert verify(client, identifier, image=PNG + b"x" * 200).json()["error"]["code"] == "image_too_large"
        response = verify(client, identifier, image=PNG + b"x" * 2000)
        assert response.status_code == 413
        assert response.json()["request_id"] == response.headers["x-request-id"]
        # An iterator sends the body without a Content-Length header.
        response = client.post("/api/v1/challenges/generate", headers=AUTH, content=iter([b"x" * 600, b"x" * 600]))
        assert response.status_code == 413


def test_missing_challenge_and_method_errors(client):
    assert client.get("/api/v1/challenges/999", headers=AUTH).status_code == 404
    response = client.post("/health")
    assert response.status_code == 405
    assert response.json()["error"]["code"] == "method_not_allowed"
    assert response.headers.get("allow")


def test_live_provider_disabled_by_default(settings):
    settings.provider_mode = "disabled"
    with TestClient(create_app(settings)) as client:
        assert generate(client).json()["error"]["code"] == "provider_not_configured"
        assert generate(client).status_code == 503  # controlled failures release the key


def test_missing_server_token_fails_closed(settings):
    settings.client_token = type(settings.client_token)("")
    with TestClient(create_app(settings)) as client:
        assert client.get("/health").status_code == 200
        assert client.get("/api/v1/topics", headers=AUTH).status_code == 503


def test_unhandled_error_is_sanitized(settings):
    class BrokenProvider(MockProvider):
        def generate(self, *args):
            raise RuntimeError("PRIVATE PROVIDER TOKEN")
    with TestClient(create_app(settings, provider=BrokenProvider())) as client:
        response = generate(client)
        assert response.status_code == 500
        assert "PRIVATE" not in response.text
        assert response.json()["request_id"] == response.headers["x-request-id"]
        assert generate(client).json()["error"]["code"] == "request_in_progress"


def test_approval_completes_challenge_and_old_request_replays(settings):
    class ApprovingProvider(MockProvider):
        def verify(self, *args):
            return {"status": "approved", "confidence": 0.9, "reason": "TEST DOUBLE ONLY", "detected_objects": ["leaf"], "is_mock": True}
    with TestClient(create_app(settings, provider=ApprovingProvider())) as client:
        identifier = generate(client).json()["challenges"][0]["id"]
        result = verify(client, identifier)
        assert result.status_code == 200
        assert client.get(f"/api/v1/challenges/{identifier}", headers=AUTH).json()["status"] == "completed"
        assert verify(client, identifier).json() == result.json()
        assert verify(client, identifier, key="new").status_code == 409


def test_concurrent_duplicate_does_not_call_provider_twice(settings):
    entered, release = Event(), Event()
    class SlowProvider(MockProvider):
        calls = 0
        def generate(self, *args):
            self.calls += 1
            entered.set()
            assert release.wait(5)
            return super().generate(*args)
    provider = SlowProvider()
    with TestClient(create_app(settings, provider=provider)) as client:
        with ThreadPoolExecutor(max_workers=2) as pool:
            first = pool.submit(generate, client)
            assert entered.wait(5)
            try:
                second = generate(client)
                assert second.status_code == 409
            finally:
                release.set()
            assert first.result().status_code == 201
        assert provider.calls == 1


def test_idempotency_survives_restart(settings):
    with TestClient(create_app(settings)) as client:
        original = generate(client).json()
    with TestClient(create_app(settings)) as client:
        response = generate(client)
        assert response.json() == original
        assert response.headers["idempotency-replayed"] == "true"


def test_openapi_has_routes_security_and_idempotency(client):
    schema = client.get("/openapi.json").json()
    assert len([path for path in schema["paths"] if path.startswith("/api/v1")]) == 5
    generate_op = schema["paths"]["/api/v1/challenges/generate"]["post"]
    assert generate_op["security"]
    assert any(item["name"] == "Idempotency-Key" and item["required"] for item in generate_op["parameters"])
    assert "multipart/form-data" in schema["paths"]["/api/v1/challenges/{challenge_id}/verify"]["post"]["requestBody"]["content"]


def test_provider_receives_jpeg_and_replay_skips_processing(settings, monkeypatch):
    class InspectingProvider(MockProvider):
        calls = 0
        def verify(self, challenge, image, content_type):
            self.calls += 1
            assert content_type == "image/jpeg"
            with Image.open(BytesIO(image)) as decoded:
                assert decoded.format == "JPEG"
                assert decoded.size == (4, 2)
                assert not decoded.getexif()
            return super().verify(challenge, image, content_type)
    settings.image_max_dimension = 4
    provider = InspectingProvider()
    app = create_app(settings, provider=provider)
    with TestClient(app) as client:
        identifier = generate(client).json()["challenges"][0]["id"]
        assert verify(client, identifier).status_code == 200
        def unexpected_processing(*args):
            pytest.fail("Completed retries must bypass preprocessing")
        monkeypatch.setattr(app.state.service.image_processor, "process", unexpected_processing)
        assert verify(client, identifier).headers["idempotency-replayed"] == "true"
    assert provider.calls == 1


def test_malformed_image_releases_key_and_upload_is_closed(settings, monkeypatch):
    from starlette.datastructures import UploadFile
    closed = []
    original_close = UploadFile.close
    async def close(upload):
        await original_close(upload)
        closed.append(upload.file.closed)
    monkeypatch.setattr(UploadFile, "close", close)
    with TestClient(create_app(settings)) as client:
        identifier = generate(client).json()["challenges"][0]["id"]
        response = verify(client, identifier, image=PNG[:40])
        assert response.status_code == 422
        assert response.json()["error"]["code"] == "invalid_image"
        assert response.json()["request_id"] == response.headers["x-request-id"]
        assert verify(client, identifier).status_code == 200
    assert closed and all(closed)


def test_excess_pixels_and_mismatched_type(client, settings):
    identifier = generate(client).json()["challenges"][0]["id"]
    settings.max_image_pixels = 16
    response = verify(client, identifier)
    assert response.status_code == 413
    assert response.json()["error"]["code"] == "image_too_many_pixels"
    assert verify(client, identifier, content_type="image/jpeg").status_code == 415


def test_chunked_multipart_file_limit(settings):
    settings.max_upload_bytes = 100
    settings.max_request_bytes = 4096
    with TestClient(create_app(settings)) as client:
        identifier = generate(client).json()["challenges"][0]["id"]
        body = (b'--test\r\nContent-Disposition: form-data; name="photo"; filename="x.png"\r\n'
                b'Content-Type: image/png\r\n\r\n' + PNG + b'x' * 200 + b'\r\n--test--\r\n')
        response = client.post(
            f"/api/v1/challenges/{identifier}/verify",
            headers=dict(AUTH, **{"Idempotency-Key": "chunked", "Content-Type": "multipart/form-data; boundary=test"}),
            content=(body[i:i + 11] for i in range(0, len(body), 11)),
        )
        assert response.status_code == 413
        assert response.json()["error"]["code"] == "image_too_large"


def test_processing_runs_outside_async_event_loop(settings, monkeypatch):
    from threading import get_ident
    app = create_app(settings)
    loop_threads, worker_threads = [], []
    @app.get("/thread-check")
    async def thread_check():
        loop_threads.append(get_ident())
        return {}
    processor = app.state.service.image_processor
    original_process = processor.process
    def process(*args):
        worker_threads.append(get_ident())
        return original_process(*args)
    monkeypatch.setattr(processor, "process", process)
    with TestClient(app) as client:
        client.get("/thread-check")
        identifier = generate(client).json()["challenges"][0]["id"]
        assert verify(client, identifier).status_code == 200
    assert worker_threads and worker_threads[0] != loop_threads[0]


def test_upload_closed_when_cancelled(settings):
    import anyio
    from types import SimpleNamespace
    from starlette.datastructures import Headers, UploadFile
    from app.api.routes import verify_photo
    upload = UploadFile(BytesIO(PNG), headers=Headers({"content-type": "image/png"}))
    request = SimpleNamespace(app=SimpleNamespace(state=SimpleNamespace(settings=settings, service=None)))
    async def run():
        with anyio.CancelScope() as scope:
            scope.cancel()
            await verify_photo(1, request, "key", upload)
        assert upload.file.closed
    anyio.run(run)


def test_multipart_limit_rejects_during_receive(settings):
    import anyio
    from app.middleware import RequestBoundaryMiddleware
    settings.max_upload_bytes = 100
    settings.max_request_bytes = 4096
    received, sent = [], []
    chunks = [
        b'--test\r\nContent-Disposition: form-data; name="photo"; filename="x.png"\r\n\r\n',
        b'x' * 80, b'x' * 80, b'x' * 80 + b'\r\n--test--\r\n',
    ]
    async def downstream(*args):
        pytest.fail("Oversized file must not reach multipart spooling")
    async def receive():
        index = len(received)
        received.append(index)
        return {"type": "http.request", "body": chunks[index], "more_body": index < len(chunks) - 1}
    async def send(message):
        sent.append(message)
    scope = {"type": "http", "path": "/api/v1/challenges/1/verify", "method": "POST", "headers": [
        (b'authorization', b'Bearer test-token'),
        (b'content-type', b'multipart/form-data; boundary=test'),
    ]}
    async def run():
        await RequestBoundaryMiddleware(downstream, settings)(scope, receive, send)
    anyio.run(run)
    assert sent[0]["status"] == 413
    assert len(received) == 3  # Reject before reading the rest of the upload.
