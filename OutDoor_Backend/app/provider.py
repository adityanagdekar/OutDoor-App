"""Provider contract and explicit disabled/mock implementations."""
from typing import Protocol

from .errors import APIError
from .schemas import TOPICS


class ChallengeProvider(Protocol):
    def generate(self, topics: list[str], count: int) -> list[dict]: ...
    def verify(self, challenge: dict, image: bytes, content_type: str) -> dict: ...


class DisabledProvider:
    def generate(self, topics, count):
        raise APIError(503, "provider_not_configured", "Gemma integration is not configured.")

    def verify(self, challenge, image, content_type):
        raise APIError(503, "provider_not_configured", "Gemma integration is not configured.")


class MockProvider:
    """Explicit simulation: never claims to inspect or approve an image."""
    def generate(self, topics, count):
        titles = {topic.id: topic.title for topic in TOPICS}
        return [
            {
                "topic_id": topics[i % len(topics)],
                "title": f"MOCK challenge {i + 1}: {titles[topics[i % len(topics)]]}",
                "instruction": "Photograph an example from this topic from a safe public place. Avoid identifiable people and do not disturb animals.",
                "criteria": "Mock assignment only; no AI criteria were generated.",
                "is_mock": True,
            }
            for i in range(count)
        ]

    def verify(self, challenge, image, content_type):
        return {
            "status": "uncertain",
            "confidence": 0.0,
            "reason": "MOCK response: this image has not been analyzed by an AI model.",
            "detected_objects": [],
            "is_mock": True,
        }
