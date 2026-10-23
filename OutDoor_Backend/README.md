# OutDoor Backend — API route foundation

This phase implements the HTTP contracts, SQLite persistence, request IDs, bearer-token protection, bounded multipart intake, backend image decoding/compression, and durable idempotency. It does **not** implement live Gemma generation/vision or iOS integration. Walking rewards and Instagram accounting are untouched.

## Requirements and setup

Use Python 3.11 or newer (the system Python 3.9 is too old).

Run from this backend directory:

```bash
python3.12 -m venv .venv
source .venv/bin/activate
python -m pip install -e '.[test]'
cp .env.example .env
python -c 'import secrets; print(secrets.token_urlsafe(32))'
```

Enter the generated value into `OUTDOOR_CLIENT_TOKEN` in `.env`. Do not commit it. For an explicitly simulated local demo, set `OUTDOOR_PROVIDER_MODE=mock`. The default `disabled` mode returns `503 provider_not_configured` for AI operations. Health still works; all `/api/v1/` requests fail closed if the server token is missing.

```bash
uvicorn app.main:app --host 127.0.0.1 --port 8000 --reload
```

Open `http://127.0.0.1:8000/docs`, authorize using the client token, and test the routes. No OpenRouter credentials are needed at this stage. Do not expose development mock mode as a real verifier. For a small server, use one worker and bounded concurrency (for example `--workers 1 --limit-concurrency 4`, without `--reload`). Uvicorn overload rejections occur outside the application and may not use the JSON envelope below; proxy/server error standardization is a deployment concern.

## Routes

| Method | Path | Result |
|---|---|---|
| GET | `/health` | `200 {"status":"ok"}`; no secrets or external checks |
| GET | `/api/v1/topics` | Nine available topics |
| POST | `/api/v1/challenges/generate` | `201` saved challenge batch |
| GET | `/api/v1/challenges/{challenge_id}` | `200` saved assignment, without internal verification criteria |
| POST | `/api/v1/challenges/{challenge_id}/regenerate` | `201` replacement; original remains with `replaced` status |
| POST | `/api/v1/challenges/{challenge_id}/verify` | `200` stored assessment for multipart `photo` |

Every `/api/v1/` route requires `Authorization: Bearer <client-token>`. The three POST routes require a client-generated `Idempotency-Key` (1–128 ASCII letters/digits or `._:-`; a UUID is suitable).

Generation JSON:

```json
{
  "topic_ids": ["leaves-plants"],
  "count": 3
}
```

Topic IDs: `leaves-plants`, `sky-clouds`, `stones-textures`, `streets-architecture`, `reflections-shadows`, `cats-dogs`, `colors-shapes`, `seasonal-objects`, `surroundings-landmarks`.

Regeneration JSON:

```json
{"reason": "unsafe"}
```

Allowed reasons: `unavailable`, `unsafe`, `other`. The reason participates in the idempotency fingerprint; the mock provider does not interpret it. An actual generation prompt incorporating the reason belongs to live-provider integration.

Photo submission uses `multipart/form-data`, with a file field called `photo`. Accepts JPEG/PNG only. Default maximum image size is 5 MiB; total request maximum is 5 MiB + 64 KiB (multipart overhead included). Change these in `.env`. HEIC is not accepted yet. Requests are authenticated and size-limited before multipart parsing, including bodies without Content-Length. File contents are not written to SQLite, and the uploaded spooled file is closed on completion/error.

### Backend image processing

Pillow checks the actual format, dimensions and structure, then fully decodes JPEG/PNG uploads. Declared media type must match the detected format. Malformed/truncated files, unsupported formats and animated PNGs are rejected with the standard JSON error envelope. File extensions are ignored. HEIC is not supported.

| Environment setting | Default | Meaning |
|---|---|---|
| `OUTDOOR_MAX_UPLOAD_BYTES` | `5242880` | Maximum bytes per multipart part, including the photo |
| `OUTDOOR_MAX_REQUEST_BYTES` | `5308416` | Maximum whole request bytes, including multipart overhead |
| `OUTDOOR_MAX_IMAGE_PIXELS` | `20000000` | Maximum width × height, checked before full decoding |
| `OUTDOOR_IMAGE_MAX_DIMENSION` | `1600` | Maximum output width or height; aspect ratio preserved, no upscaling |
| `OUTDOOR_IMAGE_JPEG_QUALITY` | `80` | JPEG quality, configurable from 1–95 |

Authentication and byte checks run while receiving the body, including chunked requests without Content-Length, before Starlette parses/spools uploads. The total body is buffered only up to the configured request limit. Each multipart part also has the upload limit; the endpoint reads the photo in bounded chunks as defense in depth.

Processing applies EXIF orientation, resizes, composites transparency onto white, and encodes a fresh RGB JPEG. Source EXIF (including GPS), ICC profiles, comments and other source metadata are not copied. JPEG output may be larger than a small input PNG; the input limit is not an output size target.

Processing runs in a worker thread under a process-wide lock: only one image is decoded/compressed at a time. Deploy with **one worker** and bounded request concurrency on the 512 MB Droplet. The pixel limit bounds decoding work but is not a measured server RAM guarantee; profile memory on the Droplet before deployment. Pillow's own decompression-bomb protection remains enabled as an additional ceiling.

Image bytes are never stored in SQLite or a permanent upload folder. Processing buffers are memory-only; uploaded spooled files are closed on success/error with cleanup shielded against task cancellation. No persistent temporary directory is introduced. A process/host crash may leave OS-managed temporary files; application-level retention sweeping is not introduced here.

Errors include `413 image_too_large`, `413 request_too_large`, `413 image_too_many_pixels`, `415 unsupported_image_type` / `invalid_image_signature` / `animated_image`, and `422 invalid_image` / `empty_image`. Validation failures release the idempotency reservation and can be retried with corrected input. Completed retries skip preprocessing entirely.

Mock generation uses safe canned instructions marked `is_mock: true`. Mock verification always returns `uncertain`, zero confidence, no detected objects, and an explicit “not analyzed” explanation. It never approves a photo. Approved results in the tests come only from an injected test double.

## Request IDs and errors

Every application response has `X-Request-ID`. An incoming ID is reused only if it is 1–64 ASCII letters/digits, hyphens or underscores; otherwise one is generated. Error JSON is consistent:

```json
{
  "error": {
    "code": "challenge_not_found",
    "message": "Challenge does not exist.",
    "details": []
  },
  "request_id": "generated-or-accepted-request-id"
}
```

`details` contains sanitized field locations/types/messages for validation failures, never rejected request values. Unexpected exception messages and tracebacks are not sent to the caller. Logs contain only a safe event name and request ID. Model errors, timeouts and retry policy will be expanded when the real provider is added.

## Idempotency behavior

- Persisted in the same SQLite file as assignments and attempts. Completed records survive restart and have no automatic expiry yet.
- Scope is operation + challenge ID where applicable + key. Reuse the same key for retries of the **same** operation; use a fresh key for an intentional new assignment/attempt.
- Same key and same validated input replays the original status/body with `Idempotency-Replayed: true`. The new HTTP attempt receives its own request ID.
- Different input with an existing key returns `409 idempotency_conflict`.
- For photos, input identity is the SHA-256 of the original uploaded file bytes plus media type (before preprocessing); filename and multipart boundary changes do not create new attempts.
- Concurrent identical requests receive `409 request_in_progress` until the first completes. Retry with the same key after it finishes.
- Resource writes and replay records commit in one transaction. Provider work runs outside the transaction.
- Known errors release their reservation. Unknown failures or crashes leave it pending instead of silently repeating a possibly chargeable provider call. Pending records require operator review/reconciliation; automated crash recovery is not implemented. Never just switch to a new key after an ambiguous failure.
- Completed or replaced assignments reject new verification/regeneration operations; retries of earlier successful operations still replay.

SQLite creates numeric assignment and attempt IDs. No nested Git repository is created. Keep `data/`, `.env`, and uploads out of Git. Startup automatically removes the legacy `difficulty` column and strips it from cached responses, preserving assignments, relationships and verification attempts. This migration requires SQLite 3.35+; back up existing databases before upgrading. Requests no longer accept difficulty. Old generation keys may return a fingerprint conflict because their original input included difficulty; retrieve existing assignments instead of blindly retrying generation under a new key.

## Testing

```bash
python -m pytest -q
```

The route tests cover all six endpoints, authentication, field validation, OpenAPI, request IDs, replay/conflict across restart, concurrent duplicates, replacement history, photo retry fingerprints, size limits, sanitized failures, and approval via a test double.

Standard-library-only storage tests can run without installing dependencies:

```bash
python -m unittest discover -s tests -p test_database.py -v
```

## Next phases

1. Add the real OpenRouter client and strictly validate Gemma output.
2. Measure image-processing peak memory and throughput on the target Droplet.
3. Add private temporary-folder handling if necessary; delete immediately and sweep crash leftovers with configurable `3600`-second retention.
4. Connect iOS numeric challenge models and submission states. Photo failures must never revoke walking credits.
5. Deploy with HTTPS; synchronize neither walking nor Instagram data in this milestone.
