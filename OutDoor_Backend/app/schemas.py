from datetime import datetime
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, StringConstraints


class Topic(BaseModel):
    id: str
    title: str


TOPICS = [
    Topic(id="leaves-plants", title="Leaves and plants"),
    Topic(id="sky-clouds", title="Sky and clouds"),
    Topic(id="stones-textures", title="Stones and natural textures"),
    Topic(id="streets-architecture", title="Streets and architecture"),
    Topic(id="reflections-shadows", title="Reflections and shadows"),
    Topic(id="cats-dogs", title="Cats and dogs"),
    Topic(id="colors-shapes", title="Colors and geometric shapes"),
    Topic(id="seasonal-objects", title="Seasonal objects"),
    Topic(id="surroundings-landmarks", title="Surroundings and landmarks"),
]


class TopicsResponse(BaseModel):
    topics: list[Topic]


class GenerateRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    topic_ids: list[str] = Field(min_length=1, max_length=9)
    count: int = Field(default=3, ge=1, le=5, strict=True)


class RegenerateRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    reason: Literal["unavailable", "unsafe", "other"] = "unavailable"


class Challenge(BaseModel):
    id: int
    topic_id: str
    title: str
    instruction: str
    status: Literal["assigned", "completed", "replaced"]
    created_at: datetime
    replaces_id: int | None = None
    replaced_by_id: int | None = None
    is_mock: bool


class ChallengeBatch(BaseModel):
    challenges: list[Challenge]
    is_mock: bool


class GemmaAssessment(BaseModel):
    """Only assessment fields may come from the vision model."""
    model_config = ConfigDict(extra="forbid", strict=True)
    status: Literal["approved", "rejected", "uncertain"]
    confidence: float = Field(ge=0, le=1, allow_inf_nan=False)
    reason: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=1500)]
    detected_objects: list[Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=100)]] = Field(max_length=30)


class ProviderAssessment(GemmaAssessment):
    is_mock: bool


class Verification(ProviderAssessment):
    # Public records are loaded from SQLite, whose timestamps are strings.
    model_config = ConfigDict(extra="forbid", strict=False)
    attempt_id: int
    challenge_id: int
    created_at: datetime


class ErrorDetail(BaseModel):
    code: str
    message: str
    details: list[dict] = Field(default_factory=list)


class ErrorResponse(BaseModel):
    error: ErrorDetail
    request_id: str
