"""Storage/idempotency tests run with the Python standard library alone."""
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from app.database import Database
from app.errors import APIError


class DatabaseTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.path = Path(self.directory.name) / "test.sqlite3"
        self.db = Database(self.path)
        self.db.initialize()

    def tearDown(self):
        self.directory.cleanup()

    def item(self):
        return {"topic_id": "leaves-plants", "title": "A leaf", "instruction": "Find a leaf", "criteria": "A visible leaf", "is_mock": True}

    def test_replay_survives_new_database_instance(self):
        self.assertIsNone(self.db.claim("generate", "key", "fingerprint"))
        with self.db.connect() as connection:
            self.db.complete(connection, "generate", "key", 201, {"id": 12})
        reopened = Database(self.path)
        self.assertEqual(reopened.claim("generate", "key", "fingerprint"), (201, {"id": 12}))

    def test_same_key_different_payload_conflicts(self):
        self.db.claim("generate", "key", "first")
        with self.assertRaises(APIError) as caught:
            self.db.claim("generate", "key", "second")
        self.assertEqual(caught.exception.code, "idempotency_conflict")

    def test_pending_request_is_not_repeated(self):
        self.db.claim("verify:1", "key", "fingerprint")
        with self.assertRaises(APIError) as caught:
            self.db.claim("verify:1", "key", "fingerprint")
        self.assertEqual(caught.exception.code, "request_in_progress")

    def test_operations_scope_keys(self):
        self.assertIsNone(self.db.claim("verify:1", "key", "fingerprint"))
        self.assertIsNone(self.db.claim("verify:2", "key", "fingerprint"))

    def test_controlled_failure_can_release_reservation(self):
        self.db.claim("generate", "key", "fingerprint")
        self.db.release("generate", "key")
        self.assertIsNone(self.db.claim("generate", "key", "fingerprint"))

    def test_release_does_not_delete_completed_response(self):
        self.db.claim("generate", "key", "fingerprint")
        with self.db.connect() as connection:
            self.db.complete(connection, "generate", "key", 201, {"id": 12})
        self.db.release("generate", "key")
        self.assertEqual(self.db.claim("generate", "key", "fingerprint"), (201, {"id": 12}))

    def test_business_write_and_response_commit_atomically(self):
        self.db.claim("generate", "key", "fingerprint")
        with self.assertRaises(RuntimeError):
            with self.db.connect() as connection:
                self.db.insert_challenge(connection, self.item())
                self.db.complete(connection, "generate", "key", 201, {"id": 1})
                raise RuntimeError("simulate failure before commit")
        with self.db.connect() as connection:
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM challenges").fetchone()[0], 0)
        with self.assertRaises(APIError) as caught:
            self.db.claim("generate", "key", "fingerprint")
        self.assertEqual(caught.exception.code, "request_in_progress")

    def test_concurrent_claim_only_one_wins(self):
        def claim(_):
            try:
                self.db.claim("generate", "shared", "fingerprint")
                return "claimed"
            except APIError as error:
                return error.code
        with ThreadPoolExecutor(max_workers=4) as pool:
            results = list(pool.map(claim, range(4)))
        self.assertEqual(results.count("claimed"), 1)
        self.assertEqual(results.count("request_in_progress"), 3)

    def test_numeric_ids_and_verification_metadata(self):
        with self.db.connect() as connection:
            challenge = self.db.insert_challenge(connection, self.item())
            self.assertIsInstance(challenge["id"], int)
            result = self.db.insert_verification(connection, challenge["id"], {"status": "approved", "confidence": 0.9, "reason": "Test only", "detected_objects": ["leaf"], "is_mock": True})
        self.assertEqual(result["challenge_id"], challenge["id"])
        self.assertEqual(self.db.get_challenge(challenge["id"])["status"], "completed")

    def test_migration_preserves_records_relationships_and_cached_responses(self):
        with self.db.connect() as connection:
            original = self.db.insert_challenge(connection, self.item())
            replacement = self.db.insert_challenge(connection, self.item(), original["id"])
            connection.execute("UPDATE challenges SET status = 'replaced', replaced_by_id = ? WHERE id = ?", (replacement["id"], original["id"]))
            self.db.insert_verification(connection, replacement["id"], {"status": "uncertain", "confidence": 0, "reason": "Test", "detected_objects": [], "is_mock": True})
            connection.execute("ALTER TABLE challenges ADD COLUMN difficulty TEXT NOT NULL DEFAULT 'easy'")
        for operation, response in [("regenerate:1", dict(replacement, difficulty="easy")), ("generate", {"challenges": [dict(original, difficulty="easy")], "is_mock": True})]:
            self.db.claim(operation, "old", "fingerprint")
            with self.db.connect() as connection:
                self.db.complete(connection, operation, "old", 201, response)

        self.db.initialize()
        self.db.initialize()  # Migration is safe to repeat.
        with self.db.connect() as connection:
            self.assertNotIn("difficulty", {row["name"] for row in connection.execute("PRAGMA table_info(challenges)")})
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM verifications").fetchone()[0], 1)
            self.assertEqual(connection.execute("PRAGMA foreign_key_check").fetchall(), [])
            new = self.db.insert_challenge(connection, self.item())
            self.assertGreater(new["id"], replacement["id"])
        self.assertEqual(self.db.get_challenge(original["id"])["replaced_by_id"], replacement["id"])
        self.assertEqual(self.db.get_challenge(replacement["id"])["replaces_id"], original["id"])
        self.assertNotIn("difficulty", self.db.claim("regenerate:1", "old", "fingerprint")[1])
        batch = self.db.claim("generate", "old", "fingerprint")[1]
        self.assertNotIn("difficulty", batch["challenges"][0])


if __name__ == "__main__":
    unittest.main()
