# Validation status

## Current implementation: tests deferred

The following changes were implemented after the last full test run and have **not been validated by a new test run**:

- Opt-in OpenRouter vision provider, application-owned asynchronous HTTP client, assessment schema validation, prompt rules for untrusted photo text, bounded provider responses and timeout/error handling.
- Provider-outcome-unknown handling that preserves pending idempotency reservations after ambiguous communication failures.
- SQLite model metadata, assignment update timestamps, explicit idempotency status/completion timestamps, additive startup migrations and lookup indexes.
- Private multipart upload files, folder/file permissions, cancellation-safe deletion, file locking, startup sweeping and periodic stale-file cleanup.

Tests and documentation were intentionally deferred at the user's request. This documentation update changes README.md, .env.example and VALIDATION.md only; it adds no tests, runs no tests and makes no live provider calls. The historical 56-test result below is not evidence that the current implementation passes.

## Pending validation work

When testing is requested, review/update existing fixtures and add focused coverage for:

- Saved SQLite criteria as the only verification criteria source; phone input and text within photos cannot supply server instructions.
- Strict status/confidence/reason/object validation, malformed/incomplete/refused model responses and unexpected fields.
- Live provider request formatting, reusable-client lifespan and shutdown, configured model selection, actual/requested model metadata and mock/live separation.
- Provider credential, balance, rate-limit, connection and response failures; retry-safe errors versus ambiguous timeouts that retain the reservation; no false rejection or saved attempt on provider failure.
- Approval completion, rejection/uncertainty permitting another attempt, concurrent status changes and atomic replay persistence.
- Repeatable migrations from existing schemas, preservation of IDs/replacement links/criteria/attempts/cached responses, NULL historical metadata, timestamp updates and pending/completed idempotency status.
- Short transactions: no open SQLite transaction during image preprocessing or provider I/O.
- Random private filenames, modes 0700/0600, rejection of unsafe directory ownership/permissions/symlinks and uploads outside public paths.
- Cleanup after success, invalid fields, malformed/incomplete multipart input, byte-limit errors, provider failure, timeout and cancellation, including cancellation before endpoint execution.
- One-file multipart limits, original deletion before provider I/O, and processed images remaining in memory.
- Startup/periodic cleanup, the 3,600-second default, configurable thresholds, active/cross-worker locks, unrelated files and symlinks, unlink failures, restart after crash, and graceful cleanup-task shutdown.
- Regression coverage for all routes, image processing, authentication, request IDs, idempotency and difficulty removal.

No automated test can guarantee a model always ignores prompt injection. Live behavior needs separate evaluation after configuration. No live Gemma calls, deployed-server checks, iPhone integration or target-Droplet peak-memory measurements have been completed. Provider-side data retention and any offline OS cleanup job remain separate operational work.

## Commands for a later test session

From OutDoor_Backend, using Python 3.11+:

```bash
source .venv/bin/activate
python -m pip install -e '.[test]'
python -m pytest -q
```

Database-only tests can run without installing FastAPI/test dependencies:

```bash
python -m unittest discover -s tests -p test_database.py -v
```

Startup tests should use isolated temporary database and image-directory settings so tests do not create or modify the development database/upload folder. Do not enable live credentials during routine tests; use injected providers or mocked HTTP transports. Any future paid live checks should be explicitly requested.

## Historical result: image-processing milestone

Before the later verification/storage/temporary-file changes:

- Changes were applied directly in the actual OutDoor_Backend repository; no iOS code was edited.
- Read/write access was verified with a temporary file, then the file was removed.
- Backend/test dependencies were installed in the ignored local .venv using bundled Python 3.12 and Pillow 12.3.0.
- `.venv/bin/python -m pytest -q`: **56 passed**, including 10 database tests and the then-current HTTP tests.
- Coverage included JPEG/PNG decoding, malformed/truncated data, detected-type mismatch, animation rejection, pre-decode pixel limits, aspect ratio/no upscaling, EXIF orientation, metadata stripping, transparency, serial processing, execution outside the event loop, streamed multipart byte limits, upload cleanup and idempotent replay bypassing processing.
- One third-party warning reported deprecation of Starlette's httpx-based TestClient.
- No live provider, deployment, iPhone or Droplet-memory checks were run.

## Earlier history

Difficulty removal passed 10 standard-library database tests, including the legacy-column migration preserving relationships, attempts and replay bodies. Before dependencies became available, HTTP tests were written but not executed; that earlier limitation was resolved for the image-processing milestone only. References in old handoff notes to staging copies or denied destination writes are obsolete: the implementation is now in the actual repository.
