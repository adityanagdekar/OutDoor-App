class APIError(Exception):
    def __init__(self, status: int, code: str, message: str, *, release_idempotency: bool = True):
        self.status = status
        self.code = code
        self.message = message
        self.release_idempotency = release_idempotency


def error_response(status, code, message, request_id, details=None):
    from fastapi.responses import JSONResponse

    return JSONResponse(
        status_code=status,
        content={
            "error": {"code": code, "message": message, "details": details or []},
            "request_id": request_id,
        },
    )
