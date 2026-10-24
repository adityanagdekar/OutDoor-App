# OutDoor backend

FastAPI backend for outdoor photo challenges, SQLite assignments and verification history, and opt-in Gemma vision verification through OpenRouter. Image inference runs remotely; decoding and compression run on the backend.

Implemented: authenticated routes, numeric IDs, replacement relationships, request IDs, durable idempotency, bounded JPEG/PNG intake, image processing, strict assessment validation, model metadata storage, and private temporary-upload cleanup.

Live challenge generation, iPhone integration, deployment and target-Droplet memory profiling remain pending. Mock mode is an explicit simulation. Walking rewards are independent of photo outcomes: rejection, uncertainty and provider errors never remove walking credits. The backend stores no walking routes or Instagram accounting.

## Local setup

Use Python 3.11+ and SQLite 3.35+ (required for the legacy difficulty migration). The temporary-file implementation targets macOS and Linux and uses POSIX file locks.

Run from the actual backend directory:

```bash
cd /Users/aditya/Documents/Project/Mac-Apps/OutDoor/OutDoor_Backend
python3.12 -m venv .venv
source .venv/bin/activate
python -m pip install -e .
cp .env.example .env
python -c 'import secrets; print(secrets.token_urlsafe(32))'
```

Copy the generated token into `OUTDOOR_CLIENT_TOKEN` in `.env`. Keep `.env` private and out of Git. The iPhone should keep its copy in Keychain and send `Authorization: Bearer <client-token>`. The OpenRouter key is a separate server-only credential.

Start the development server from this directory:

```bash
uvicorn app.main:app --host 127.0.0.1 --port 8000 --reload
```

`/health` is public. `/docs` provides the API interface; authorize with the client token for functional endpoints. Startup creates the configured SQLite database and temporary-image directory, applies database migrations, sweeps stale temporary files and starts periodic cleanup. The folders do not have to exist beforehand. Back up an existing database before upgrading.

## Configuration

Settings load from environment variables and `.env` in the working directory. Relative filesystem paths also resolve from the working directory. Restart the backend after changing settings.

| Environment variable | Default | Purpose |
|---|---|---|
| `OUTDOOR_CLIENT_TOKEN` | Empty | Expected bearer token; functional routes fail closed when empty |
| `OUTDOOR_DATABASE_PATH` | `data/outdoor.sqlite3` | SQLite file; parent folder created at startup |
| `OUTDOOR_PROVIDER_MODE` | `disabled` | `disabled`, `mock` or `openrouter` |
| `OUTDOOR_OPENROUTER_API_KEY` | Empty | Server-only provider credential, separate from client token |
| `OUTDOOR_OPENROUTER_VISION_MODEL` | Empty | Exact configured vision-capable Gemma model identifier; no default model selected |
| `OUTDOOR_OPENROUTER_TIMEOUT_SECONDS` | `45` | Overall provider deadline and HTTP timeout; greater than 0, at most 180 |
| `OUTDOOR_MAX_UPLOAD_BYTES` | `5242880` | 5 MiB limit per multipart part, including the photo |
| `OUTDOOR_MAX_REQUEST_BYTES` | `5308416` | Whole request limit, including multipart overhead; must exceed upload limit |
| `OUTDOOR_MAX_IMAGE_PIXELS` | `20000000` | Maximum input width × height before full decoding |
| `OUTDOOR_IMAGE_MAX_DIMENSION` | `1600` | Maximum output width or height, preserving aspect ratio |
| `OUTDOOR_IMAGE_JPEG_QUALITY` | `80` | JPEG quality from 1 to 95 |
| `OUTDOOR_TEMP_IMAGE_DIRECTORY` | `data/tmp_images` | Dedicated private upload directory; never publicly served |
| `OUTDOOR_TEMP_MAX_AGE_SECONDS` | `3600` | Age threshold for abandoned temporary files; positive integer |
| `OUTDOOR_TEMP_CLEANUP_INTERVAL_SECONDS` | `60` | Periodic sweep interval, from 1 to 3600 seconds; clamped to maximum age |

With the working directory above, the default paths are:

```text
OutDoor_Backend/data/outdoor.sqlite3
OutDoor_Backend/data/tmp_images/
```

The existing `.gitignore` excludes `data/`, `.env`, `.venv/` and uploads. If configuring paths elsewhere, keep those files private and outside Git and public web-server roots.

## Provider modes

| Mode | Generation / regeneration | Verification |
|---|---|---|
| `disabled` | `503 provider_not_configured` | `503 provider_not_configured` for an otherwise valid submission |
| `mock` | Saved canned challenges marked `is_mock: true` | Always `uncertain`, confidence `0`, no detected objects, explicit “not analyzed” reason |
| `openrouter` | `503 generation_not_configured` | Live assessment of an existing, active, non-mock assignment with saved criteria |

For simulated local development, set `OUTDOOR_PROVIDER_MODE=mock`. No OpenRouter key is needed.

Live verification requires all three settings:

```dotenv
OUTDOOR_PROVIDER_MODE=openrouter
OUTDOOR_OPENROUTER_API_KEY=<server-only-key>
OUTDOOR_OPENROUTER_VISION_MODEL=<vision-capable-gemma-model-id>
```

Do not copy placeholder values into a running configuration. Model availability and vision compatibility must be confirmed when configuring the provider. No live model has been exercised in this project yet. Live calls may incur provider charges and send the processed JPEG to OpenRouter and its inference provider. Local deletion does not establish provider-side retention; review the selected provider's data policy before submitting private photos.

Switching a mock-generated assignment to live verification returns `409 mock_challenge`. Live generation is still missing, so mock generation followed by live verification is not yet a supported end-to-end workflow. The live adapter does not automatically retry requests. It reuses one asynchronous HTTP client for the application lifespan, limits response bodies to 64 KiB, and limits output to 1,024 tokens.

## API routes

| Method | Path | Result |
|---|---|---|
| GET | `/health` | `200 {"status":"ok"}`; no external checks or secrets |
| GET | `/api/v1/topics` | Nine stable topic IDs and titles |
| POST | `/api/v1/challenges/generate` | `201` saved challenge batch |
| GET | `/api/v1/challenges/{challenge_id}` | Saved assignment and status, without internal criteria or model metadata |
| POST | `/api/v1/challenges/{challenge_id}/regenerate` | `201` linked replacement; original retained as `replaced` |
| POST | `/api/v1/challenges/{challenge_id}/verify` | `200` stored assessment and numeric attempt ID |

All `/api/v1/` routes require the client bearer token. POST routes also require `Idempotency-Key`: 1–128 ASCII letters/digits or `._:-`; a UUID is suitable. Challenge IDs are positive integers.

Generation input:

```json
{"topic_ids": ["leaves-plants"], "count": 3}
```

Choose 1–9 unique topic IDs and a challenge count from 1–5. Topic IDs are `leaves-plants`, `sky-clouds`, `stones-textures`, `streets-architecture`, `reflections-shadows`, `cats-dogs`, `colors-shapes`, `seasonal-objects`, and `surroundings-landmarks`. Difficulty is removed and rejected in generation inputs. Optional environment input is not implemented. iOS owns topic icon mappings.

Regeneration input:

```json
{"reason": "unsafe"}
```

Allowed reasons: `unavailable`, `unsafe`, `other`. The reason participates in the idempotency fingerprint; canned mock generation does not interpret it. Regeneration retains the original criteria and history and creates a separate assignment with replacement links.

Verification accepts one multipart file named `photo`, declared as `image/jpeg` or `image/png`. Filenames are ignored for image validation and storage naming. No phone-supplied criteria are used. The private parser allows at most one file, eight text fields and 64 KiB per text field; callers should send only `photo`.

## Image processing and verification

Authentication and whole-request/per-part byte checks happen as the body arrives, including requests without Content-Length. The bounded request body is buffered before multipart upload parsing. The endpoint reads the photo in bounded chunks and deletes its temporary disk copy immediately after reading it.

Pillow checks detected format, declared type, dimensions and structure before full decoding. It rejects unsupported formats, animated PNGs, excessive pixel counts and malformed/truncated images. HEIC is not supported. Processing applies EXIF orientation, resizes without upscaling, composites transparency onto white, and encodes a fresh RGB JPEG. Source EXIF/GPS, ICC profiles, comments and other metadata are not copied. The input limit is not an output size target; a small PNG can produce a larger JPEG.

CPU-heavy processing runs in a worker thread under a process-wide lock, one image at a time. Processed JPEGs remain in memory and are not written to a processed-image folder.

The verification service loads the active assignment and its saved criteria from SQLite. The live provider sends only the criteria and processed JPEG for assessment. Its server-controlled prompt treats text, signs, QR codes and apparent instructions inside photos as untrusted visual content. These prompt rules reduce prompt-injection risk; they do not guarantee model behavior.

Model output is validated independently of database-owned IDs and timestamps: status must be `approved`, `rejected` or `uncertain`; confidence must be a finite number from 0–1; reason must be nonblank and at most 1,500 characters; detected objects are limited to 30 nonblank strings of at most 100 characters each. Unexpected model fields, malformed JSON, refusals and incomplete completions are provider errors. No confidence threshold is used to override the selected status.

Approval saves an attempt and completes the assignment atomically. Rejection or uncertainty saves an attempt and leaves the assignment active for another submission with a fresh idempotency key. Provider failures save no assessment and never become rejections. None of these operations modifies walking credits.

## SQLite storage

| Table | Stored data |
|---|---|
| `challenges` | Numeric ID, topic, title, instruction, internal criteria, assignment status, creation/update timestamps, generation model identifier, replacement links, mock flag |
| `verifications` | Numeric attempt ID, assignment link, status, confidence, reason, detected-object names, timestamp, verification model identifier, mock flag |
| `idempotency` | Operation scope, hashed key, input fingerprint, cached response/status code, pending/completed status, creation/completion timestamps |

The actual verification model identifier comes from the provider response envelope when present, with the requested identifier as fallback; it is not taken from the model's assessment JSON. Mock results record `mock`. Historical metadata that was never recorded stays NULL. Model identifiers remain internal storage metadata rather than public response fields.

There are no photo/blob columns, precise walking routes, Instagram accounting, or user registration tables. Foreign keys preserve assignment/attempt and replacement relationships. WAL mode and lookup indexes support history and relationship queries.

Idempotency reservation uses a short transaction. The connection closes before image processing and Gemma work. After validation, a separate short transaction commits the assignment/attempt, status changes and replay record together. No database transaction waits for Gemma.

Startup migrations add missing metadata columns and indexes without deleting records or resetting IDs. Historical completed replay records receive `completed` status without inventing completion timestamps. The legacy `difficulty` column and difficulty fields in cached bodies are removed while preserving records. Old generation keys whose fingerprints included difficulty can conflict; retrieve the saved assignments rather than blindly generating replacements.

## Idempotency and provider failures

- Scope is operation plus challenge ID where applicable plus the hashed key. Completed records survive restarts and have no automatic expiry.
- Same key/input replays the original response with `Idempotency-Replayed: true` and a fresh HTTP request ID. Retries of successful operations still replay after an assignment is completed or replaced.
- Different input under the same key returns `409 idempotency_conflict`.
- Photo identity uses SHA-256 of the original uploaded bytes plus declared media type, before preprocessing. Filename and multipart boundary do not matter. Completed retries skip image processing and provider calls, but still pass intake checks.
- Concurrent duplicates return `409 request_in_progress` while the first operation is pending.
- Normal validation/provider failures release the reservation, permitting a same-key retry. Once an attempt succeeds, intentional new attempts require new keys.
- Credential/balance failures return `503 provider_credentials_error`; connection failures, rate limits and upstream server failures return `503 provider_unavailable`. Other provider request failures or invalid assessments return `502` errors. Fix configuration issues before retrying; there are no automatic credential retries.
- An ambiguous communication failure after possible submission returns `504 provider_outcome_unknown` and keeps the reservation pending. Unknown application failures and crashes also leave pending records. Review/reconcile them before retrying a possibly billed operation. Do not bypass them with a new key. Automated reconciliation is not implemented.

## Temporary-image privacy and cleanup

Startup creates the dedicated temporary directory with mode `0700`. It must be a real directory owned by the server user with exactly those permissions; startup rejects a symlink or an existing directory with unsafe ownership/permissions rather than silently changing it. Uploaded files have random names such as `outdoor-image-ab12cd34.tmp`, mode `0600`, and never use the phone's filename.

The custom multipart route parser places file data in this private directory rather than the global OS temp folder. Uploads are closed/unlinked immediately after reading, and cleanup also runs for validation failures, incomplete parsing, provider errors, timeouts and cancellation. Cleanup finalizers are shielded against cancellation. Unlink failures log a safe event and leave the file eligible for a later sweep.

A startup sweep and a periodic worker remove owned stale files once their modification time is older than `OUTDOOR_TEMP_MAX_AGE_SECONDS` (default **3,600 seconds**). With the default 60-second interval, deletion occurs on the next sweep after the age threshold, not at an exact one-hour deadline. File locks protect active uploads, including across workers. Sweeps skip symlinks, directories and unrelated filenames and do not log image contents or metadata.

The cleanup task stops on application shutdown. A stopped/crashed server cannot run cleanup; stale files are handled when it restarts. Strict deletion while offline would require a separately configured OS-level cleanup job, which is not included. Temporary-file cleanup does not delete SQLite records or resolve pending idempotency operations.

## Request IDs and errors

Every application response includes `X-Request-ID`. Incoming IDs are accepted only when they contain 1–64 ASCII letters/digits, hyphens or underscores; otherwise the server generates one.

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

Validation details include sanitized field locations/types/messages, without rejected input values. Unexpected exception details and provider response bodies are not returned. Application error/cleanup logs use safe event names, with request IDs where available; do not enable request-body or credential logging.

Image errors include `413 image_too_large`, `413 request_too_large`, `413 image_too_many_pixels`, `415 unsupported_image_type` / `invalid_image_signature` / `animated_image`, and `422 invalid_image` / `empty_image`. Malformed multipart uploads return `400 bad_request`. Completed/replaced assignments reject new verification or regeneration with `409 challenge_not_active`.

## Validation and deployment status

Testing is tracked in [VALIDATION.md](VALIDATION.md). The earlier 56-test pass predates the verification, storage-metadata and private temporary-file changes. Those changes still require testing; no new test run is claimed by this documentation update.

When testing is requested, install test dependencies and run from the backend directory:

```bash
python -m pip install -e '.[test]'
python -m pytest -q
```

The database-only suite can also run with the standard library:

```bash
python -m unittest discover -s tests -p test_database.py -v
```

For the planned 512 MB DigitalOcean Droplet, use one worker and bounded request concurrency, for example `--workers 1 --limit-concurrency 4` without `--reload`, and profile peak RAM before deployment. One processing lock does not bound all buffered concurrent requests or guarantee server memory usage. Uvicorn/proxy overload errors may be outside the application's JSON envelope. HTTPS, deployment, live generation, live model checks, iPhone integration and provider-retention review remain pending. No new hosting provider is needed.
