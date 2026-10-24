import hashlib
from anyio import CancelScope
from typing import Annotated

from fastapi import APIRouter, Depends, File, Header, Path, Request, UploadFile
from fastapi.responses import JSONResponse
from fastapi.security import HTTPBearer
from starlette.concurrency import run_in_threadpool

from ..errors import APIError
from .uploads import PrivateUploadRoute
from ..schemas import (
    TOPICS, Challenge, ChallengeBatch, ErrorResponse, GenerateRequest,
    RegenerateRequest, TopicsResponse, Verification,
)

responses = {
    status: {"model": ErrorResponse}
    for status in (400, 401, 404, 409, 413, 415, 422, 500, 502, 503, 504)
}
router = APIRouter(
    prefix="/api/v1", dependencies=[Depends(HTTPBearer(auto_error=False))], responses=responses,
    route_class=PrivateUploadRoute,
)


def idempotency_key(
    value: Annotated[str, Header(alias="Idempotency-Key", min_length=1, max_length=128, pattern=r"^[A-Za-z0-9._:-]+$")],
):
    # Store only a digest, not arbitrary client-controlled keys.
    return hashlib.sha256(value.encode()).hexdigest()


Key = Annotated[str, Depends(idempotency_key)]
Identifier = Annotated[int, Path(gt=0)]


def mutation_response(result):
    status, body, replayed = result
    return JSONResponse(status_code=status, content=body, headers={"Idempotency-Replayed": str(replayed).lower()})


@router.get("/topics", response_model=TopicsResponse, tags=["Topics"])
def topics():
    return TopicsResponse(topics=TOPICS)


@router.post("/challenges/generate", status_code=201, response_model=ChallengeBatch, tags=["Challenges"])
def generate_challenges(payload: GenerateRequest, request: Request, key: Key):
    allowed = {topic.id for topic in TOPICS}
    if len(set(payload.topic_ids)) != len(payload.topic_ids) or any(topic not in allowed for topic in payload.topic_ids):
        raise APIError(422, "invalid_topics", "Use unique topic IDs returned by the topics endpoint.")
    return mutation_response(request.app.state.service.generate(payload, key))


@router.get("/challenges/{challenge_id}", response_model=Challenge, tags=["Challenges"])
def get_challenge(challenge_id: Identifier, request: Request):
    # Internal photo criteria deliberately do not appear in the public response.
    return Challenge.model_validate(request.app.state.database.get_challenge(challenge_id))


@router.post("/challenges/{challenge_id}/regenerate", status_code=201, response_model=Challenge, tags=["Challenges"])
def regenerate_challenge(challenge_id: Identifier, payload: RegenerateRequest, request: Request, key: Key):
    return mutation_response(request.app.state.service.regenerate(challenge_id, payload, key))


@router.post("/challenges/{challenge_id}/verify", response_model=Verification, tags=["Verification"])
async def verify_photo(challenge_id: Identifier, request: Request, key: Key, photo: Annotated[UploadFile, File(description="JPEG or PNG camera photo. Mock mode does not perform AI analysis.")]):
    try:
        # The request boundary has already enforced total bytes before parsing.
        content_type = (photo.content_type or "").lower()
        if content_type not in {"image/jpeg", "image/png"}:
            raise APIError(415, "unsupported_image_type", "Submit a JPEG or PNG image.")
        limit = request.app.state.settings.max_upload_bytes
        image = bytearray()
        while chunk := await photo.read(min(65536, limit + 1 - len(image))):
            image.extend(chunk)
            if len(image) > limit:
                raise APIError(413, "image_too_large", "Image exceeds the configured byte limit.")
        # Processing/provider calls use memory, so remove the original disk
        # copy immediately rather than retaining it throughout the AI request.
        await photo.close()
        if not image:
            raise APIError(422, "empty_image", "The photo is empty.")
        # Early signature rejection; the worker also validates actual content.
        signature_matches = (
            content_type == "image/jpeg" and image.startswith(b"\xff\xd8\xff")
        ) or (
            content_type == "image/png" and image.startswith(b"\x89PNG\r\n\x1a\n")
        )
        if not signature_matches:
            raise APIError(415, "invalid_image_signature", "Image signature does not match its declared type.")
        result = await run_in_threadpool(request.app.state.service.verify, challenge_id, bytes(image), content_type, key)
        return mutation_response(result)
    finally:
        # Also closes/deletes the private temporary upload on errors.
        with CancelScope(shield=True):
            await photo.close()
