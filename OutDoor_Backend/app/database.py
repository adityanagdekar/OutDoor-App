import json
import sqlite3
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

from .errors import APIError


def now():
    return datetime.now(timezone.utc).isoformat()


class Database:
    def __init__(self, path: Path):
        self.path = path

    @contextmanager
    def connect(self):
        connection = sqlite3.connect(self.path, timeout=5)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys = ON")
        try:
            with connection:
                yield connection
        finally:
            connection.close()

    def initialize(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.connect() as db:
            db.execute("PRAGMA journal_mode = WAL")
            db.executescript("""
                CREATE TABLE IF NOT EXISTS challenges (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    topic_id TEXT NOT NULL,
                    title TEXT NOT NULL,
                    instruction TEXT NOT NULL,
                    criteria TEXT NOT NULL,
                    status TEXT NOT NULL DEFAULT 'assigned',
                    created_at TEXT NOT NULL,
                    replaces_id INTEGER REFERENCES challenges(id),
                    replaced_by_id INTEGER REFERENCES challenges(id),
                    is_mock INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS verifications (
                    attempt_id INTEGER PRIMARY KEY AUTOINCREMENT,
                    challenge_id INTEGER NOT NULL REFERENCES challenges(id),
                    status TEXT NOT NULL,
                    confidence REAL NOT NULL,
                    reason TEXT NOT NULL,
                    detected_objects TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    is_mock INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS idempotency (
                    operation TEXT NOT NULL,
                    key TEXT NOT NULL,
                    fingerprint TEXT NOT NULL,
                    response TEXT,
                    status_code INTEGER,
                    created_at TEXT NOT NULL,
                    PRIMARY KEY(operation, key)
                );
            """)
            # Migrate the original schema without deleting assignments or attempts.
            db.execute("BEGIN IMMEDIATE")
            columns = {row["name"] for row in db.execute("PRAGMA table_info(challenges)")}
            if "difficulty" in columns:
                db.execute("ALTER TABLE challenges DROP COLUMN difficulty")
                # Cached regeneration/batch responses must use the new contract too.
                for row in db.execute("SELECT operation, key, response FROM idempotency WHERE response IS NOT NULL").fetchall():
                    body = json.loads(row["response"])
                    body.pop("difficulty", None)
                    for challenge in body.get("challenges", []):
                        challenge.pop("difficulty", None)
                    db.execute(
                        "UPDATE idempotency SET response = ? WHERE operation = ? AND key = ?",
                        (json.dumps(body), row["operation"], row["key"]),
                    )

    def get_challenge(self, identifier, db=None):
        if db is None:
            with self.connect() as connection:
                return self.get_challenge(identifier, connection)
        row = db.execute("SELECT * FROM challenges WHERE id = ?", (identifier,)).fetchone()
        if row is None:
            raise APIError(404, "challenge_not_found", "Challenge does not exist.")
        return dict(row)

    def claim(self, operation, key, fingerprint):
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            existing = db.execute(
                "SELECT * FROM idempotency WHERE operation = ? AND key = ?",
                (operation, key),
            ).fetchone()
            if existing:
                if existing["fingerprint"] != fingerprint:
                    raise APIError(409, "idempotency_conflict", "This key was already used with different input.")
                if existing["response"] is None:
                    raise APIError(409, "request_in_progress", "This operation is pending. Retry the same key later; an interrupted operation may require operator review.")
                return existing["status_code"], json.loads(existing["response"])
            db.execute(
                "INSERT INTO idempotency(operation, key, fingerprint, created_at) VALUES (?, ?, ?, ?)",
                (operation, key, fingerprint, now()),
            )
        return None

    def release(self, operation, key):
        with self.connect() as db:
            db.execute("DELETE FROM idempotency WHERE operation = ? AND key = ? AND response IS NULL", (operation, key))

    def complete(self, db, operation, key, status, body):
        db.execute(
            "UPDATE idempotency SET response = ?, status_code = ? WHERE operation = ? AND key = ?",
            (json.dumps(body), status, operation, key),
        )

    def insert_challenge(self, db, item, replaces_id=None):
        cursor = db.execute(
            """INSERT INTO challenges(topic_id, title, instruction, criteria,
               created_at, replaces_id, is_mock) VALUES (?, ?, ?, ?, ?, ?, ?)""",
            (item["topic_id"], item["title"], item["instruction"], item["criteria"],
             now(), replaces_id, item["is_mock"]),
        )
        return self.get_challenge(cursor.lastrowid, db)

    def insert_verification(self, db, challenge_id, assessment):
        created_at = now()
        cursor = db.execute(
            """INSERT INTO verifications(challenge_id, status, confidence, reason,
               detected_objects, created_at, is_mock) VALUES (?, ?, ?, ?, ?, ?, ?)""",
            (challenge_id, assessment["status"], assessment["confidence"], assessment["reason"],
             json.dumps(assessment["detected_objects"]), created_at, assessment["is_mock"]),
        )
        if assessment["status"] == "approved":
            db.execute("UPDATE challenges SET status = 'completed' WHERE id = ?", (challenge_id,))
        return dict(assessment, attempt_id=cursor.lastrowid, challenge_id=challenge_id, created_at=created_at)
