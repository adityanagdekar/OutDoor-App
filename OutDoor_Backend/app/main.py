from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from starlette.exceptions import HTTPException

from .api.routes import router
from .config import Settings
from .database import Database
from .errors import APIError, error_response
from .middleware import RequestBoundaryMiddleware
from .images import ImageProcessor
from .provider import DisabledProvider, MockProvider
from .service import ChallengeService
from .verification_provider import OpenRouterVerificationProvider


def create_app(settings: Settings | None = None, provider=None):
    settings = settings or Settings()
    database = Database(settings.database_path)
    if provider is None:
        if settings.provider_mode == "openrouter":
            provider = OpenRouterVerificationProvider(settings)
        elif settings.provider_mode == "mock":
            provider = MockProvider()
        else:
            provider = DisabledProvider()

    @asynccontextmanager
    async def lifespan(app):
        database.initialize()
        if isinstance(provider, OpenRouterVerificationProvider):
            await provider.start()
        try:
            yield
        finally:
            if isinstance(provider, OpenRouterVerificationProvider):
                await provider.close()

    app = FastAPI(
        title="OutDoor challenge API", version="0.1.0", lifespan=lifespan,
        description="Photo challenge API with opt-in OpenRouter vision verification. Live generation is not implemented. Mock mode returns labeled simulated data.",
    )
    app.state.settings = settings
    app.state.database = database
    app.state.service = ChallengeService(database, provider, ImageProcessor(settings))
    app.add_middleware(RequestBoundaryMiddleware, settings=settings)

    @app.exception_handler(APIError)
    async def api_error(request: Request, error: APIError):
        return error_response(error.status, error.code, error.message, request.state.request_id)

    @app.exception_handler(RequestValidationError)
    async def validation_error(request: Request, error: RequestValidationError):
        # Exclude rejected inputs and validator context (may contain secrets).
        details = [{"location": list(item["loc"]), "type": item["type"], "message": item["msg"]} for item in error.errors()]
        return error_response(422, "validation_error", "Request validation failed.", request.state.request_id, details)

    @app.exception_handler(HTTPException)
    async def http_error(request: Request, error: HTTPException):
        codes = {400: "bad_request", 404: "not_found", 405: "method_not_allowed", 413: "request_too_large"}
        messages = {400: "Malformed request.", 404: "Route not found.", 405: "Method not allowed.", 413: "Request is too large."}
        response = error_response(error.status_code, codes.get(error.status_code, "http_error"), messages.get(error.status_code, "Request could not be processed."), request.state.request_id)
        if error.headers:
            response.headers.update(error.headers)
        return response

    @app.get("/health", tags=["Health"])
    def health():
        return {"status": "ok"}

    app.include_router(router)
    return app


app = create_app()
