import hashlib
import json

from pydantic import BaseModel, Field, ValidationError

from .database import Database, now
from .errors import APIError
from .provider import ChallengeProvider
from .schemas import Challenge, ChallengeBatch, ProviderAssessment, Verification


class GeneratedChallenge(BaseModel):
    topic_id: str
    title: str = Field(min_length=1, max_length=160)
    instruction: str = Field(min_length=1, max_length=1500)
    criteria: str = Field(min_length=1, max_length=2000)
    is_mock: bool
    model_id: str | None = Field(default=None, min_length=1, max_length=200)


def fingerprint(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


class ChallengeService:
    def __init__(self, database: Database, provider: ChallengeProvider, image_processor):
        self.database = database
        self.provider = provider
        self.image_processor = image_processor

    def mutate(self, operation, key, payload, build):
        replay = self.database.claim(operation, key, fingerprint(payload))
        if replay is not None:
            return *replay, True
        try:
            # Provider work happens outside database transactions.
            prepared = build()
            with self.database.connect() as db:
                db.execute("BEGIN IMMEDIATE")
                status, body = prepared(db)
                self.database.complete(db, operation, key, status, body)
            return status, body, False
        except APIError as error:
            if error.release_idempotency:
                self.database.release(operation, key)
            raise
        except ValidationError:
            self.database.release(operation, key)
            raise APIError(502, "invalid_provider_response", "Provider response failed validation.") from None
        # An unknown failure leaves a pending record. Do not blindly retry a
        # possibly chargeable AI operation; operator reconciliation is safer.

    def generate(self, request, key):
        def build():
            raw = self.provider.generate(request.topic_ids, request.count)
            if len(raw) != request.count:
                raise APIError(502, "invalid_provider_response", "Provider returned an unexpected challenge count.")
            items = [GeneratedChallenge.model_validate(item) for item in raw]
            if any(item.topic_id not in request.topic_ids for item in items):
                raise APIError(502, "invalid_provider_response", "Provider returned unexpected topics.")

            def save(db):
                challenges = [Challenge.model_validate(self.database.insert_challenge(db, item.model_dump(mode="json"))) for item in items]
                body = ChallengeBatch(challenges=challenges, is_mock=any(item.is_mock for item in items))
                return 201, body.model_dump(mode="json")
            return save

        return self.mutate("generate", key, request.model_dump(mode="json"), build)

    def regenerate(self, challenge_id, request, key):
        def build():
            previous = self.database.get_challenge(challenge_id)
            self.require_assigned(previous)
            raw = self.provider.generate([previous["topic_id"]], 1)
            if len(raw) != 1:
                raise APIError(502, "invalid_provider_response", "Provider must return one replacement.")
            item = GeneratedChallenge.model_validate(raw[0])
            if item.topic_id != previous["topic_id"]:
                raise APIError(502, "invalid_provider_response", "Replacement topic does not match.")

            def save(db):
                self.require_assigned(self.database.get_challenge(challenge_id, db))
                replacement = self.database.insert_challenge(db, item.model_dump(mode="json"), replaces_id=challenge_id)
                db.execute("UPDATE challenges SET status = 'replaced', replaced_by_id = ?, updated_at = ? WHERE id = ?", (replacement["id"], now(), challenge_id))
                return 201, Challenge.model_validate(replacement).model_dump(mode="json")
            return save

        return self.mutate(f"regenerate:{challenge_id}", key, request.model_dump(mode="json"), build)

    def verify(self, challenge_id, image, content_type, key):
        def build():
            challenge = self.database.get_challenge(challenge_id)
            self.require_assigned(challenge)
            processed = self.image_processor.process(image, content_type)
            raw = self.provider.verify(challenge, processed, "image/jpeg")
            # Provider output cannot supply database IDs, timestamps or fields
            # outside the assessment contract.
            assessment = ProviderAssessment.model_validate(raw)

            def save(db):
                self.require_assigned(self.database.get_challenge(challenge_id, db))
                values = assessment.model_dump()
                result = self.database.insert_verification(db, challenge_id, values)
                return 200, Verification.model_validate(result).model_dump(mode="json")
            return save

        payload = {"sha256": hashlib.sha256(image).hexdigest(), "content_type": content_type}
        return self.mutate(f"verify:{challenge_id}", key, payload, build)

    @staticmethod
    def require_assigned(challenge):
        if challenge["status"] != "assigned":
            raise APIError(409, "challenge_not_active", "This challenge is completed or has been replaced.")
