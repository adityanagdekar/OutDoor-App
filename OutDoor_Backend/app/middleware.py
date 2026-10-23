import logging
import re
import secrets
from uuid import uuid4

from starlette.datastructures import Headers, MutableHeaders
from python_multipart import MultipartParser
from python_multipart.exceptions import MultipartParseError
from python_multipart.multipart import parse_options_header

from .errors import APIError, error_response

logger = logging.getLogger("outdoor.api")


class RequestBoundaryMiddleware:
    """Authenticate before parsing; bound bodies even without Content-Length."""
    def __init__(self, app, settings):
        self.app = app
        self.settings = settings

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        headers = Headers(scope=scope)
        supplied = headers.get("x-request-id", "")
        request_id = supplied if re.fullmatch(r"[A-Za-z0-9_-]{1,64}", supplied) else uuid4().hex
        scope.setdefault("state", {})["request_id"] = request_id
        started = False

        async def send_with_id(message):
            nonlocal started
            if message["type"] == "http.response.start":
                started = True
                MutableHeaders(scope=message)["X-Request-ID"] = request_id
            await send(message)

        async def reject(status, code, message):
            response = error_response(status, code, message, request_id)
            if status == 401:
                response.headers["WWW-Authenticate"] = "Bearer"
            await response(scope, receive, send_with_id)

        try:
            if scope["path"].startswith("/api/v1/"):
                token = self.settings.client_token.get_secret_value()
                if not token:
                    return await reject(503, "authentication_not_configured", "Server client token is not configured.")
                authorization = headers.get("authorization", "")
                scheme, _, supplied_token = authorization.partition(" ")
                if scheme.lower() != "bearer" or not secrets.compare_digest(supplied_token.encode(), token.encode()):
                    return await reject(401, "unauthorized", "A valid bearer token is required.")

            if scope["method"] in {"POST", "PUT", "PATCH"}:
                limit = self.settings.max_request_bytes
                length = headers.get("content-length")
                if length is not None:
                    try:
                        declared = int(length)
                        if declared < 0:
                            raise ValueError
                    except ValueError:
                        return await reject(400, "invalid_content_length", "Invalid Content-Length.")
                    if declared > limit:
                        return await reject(413, "request_too_large", "Request exceeds the configured byte limit.")
                # Bounded buffering prevents multipart parsing of unlimited bodies.
                # Production concurrency limits must also be set on the ASGI server.
                body = bytearray()
                # Count each multipart part as network chunks arrive, before
                # Starlette can spool an oversized uploaded file to disk.
                parser = None
                media_type, options = parse_options_header(headers.get("content-type", ""))
                if media_type == b"multipart/form-data" and options.get(b"boundary"):
                    part_bytes = 0

                    def start_part():
                        nonlocal part_bytes
                        part_bytes = 0

                    def receive_part(data, start, end):
                        nonlocal part_bytes
                        part_bytes += end - start
                        if part_bytes > self.settings.max_upload_bytes:
                            raise APIError(413, "image_too_large", "Multipart part exceeds the configured upload byte limit.")

                    parser = MultipartParser(options[b"boundary"], {"on_part_begin": start_part, "on_part_data": receive_part})
                while True:
                    message = await receive()
                    if message["type"] == "http.disconnect":
                        return
                    chunk = message.get("body", b"")
                    if len(body) + len(chunk) > limit:
                        return await reject(413, "request_too_large", "Request exceeds the configured byte limit.")
                    if parser is not None:
                        try:
                            parser.write(chunk)
                        except MultipartParseError:
                            return await reject(400, "bad_request", "Malformed multipart request.")
                    body.extend(chunk)
                    if not message.get("more_body", False):
                        break
                sent_body = False

                async def replay_body():
                    nonlocal sent_body
                    if not sent_body:
                        sent_body = True
                        return {"type": "http.request", "body": bytes(body), "more_body": False}
                    return await receive()

                await self.app(scope, replay_body, send_with_id)
            else:
                await self.app(scope, receive, send_with_id)
        except APIError as error:
            if started:
                raise
            await reject(error.status, error.code, error.message)
        except Exception:
            # Never log exception messages or request bodies: they may contain secrets.
            logger.error("unhandled_request_error request_id=%s", request_id)
            if started:
                raise
            await reject(500, "internal_error", "An unexpected server error occurred.")
