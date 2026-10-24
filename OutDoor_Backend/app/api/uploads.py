"""Route-local private upload storage without global tempfile monkeypatches."""
import anyio
from fastapi.routing import APIRoute
from python_multipart.multipart import parse_options_header
from starlette.concurrency import run_in_threadpool
from starlette.formparsers import MultiPartException, MultiPartParser

from ..errors import APIError


class PrivateMultiPartParser(MultiPartParser):
    def __init__(self, headers, stream, upload_file):
        super().__init__(headers, stream, max_files=1, max_fields=8, max_part_size=65536)
        self.upload_file = upload_file

    def on_headers_finished(self):
        super().on_headers_finished()
        if self._current_part.file is not None:
            # Starlette has created an empty in-memory spool. Replace it before
            # any file bytes are written, keeping its standard field parsing.
            spool = self._current_part.file.file
            self._current_part.file.file = self.upload_file
            self._files_to_close_on_error[-1] = self.upload_file
            spool.close()


class PrivateUploadRoute(APIRoute):
    def get_route_handler(self):
        original = super().get_route_handler()

        async def handle(request):
            media_type, _ = parse_options_header(request.headers.get("content-type", ""))
            if media_type != b"multipart/form-data":
                return await original(request)

            upload = None
            form = None
            try:
                # Keep allocation shielded: cancellation must not discard a
                # newly created descriptor before the finally block owns it.
                with anyio.CancelScope(shield=True):
                    upload = await run_in_threadpool(request.app.state.temporary_images.create)
                parser = PrivateMultiPartParser(request.headers, request.stream(), upload)
                form = await parser.parse()
                # FastAPI's File dependencies reuse Request's cached FormData;
                # its default parser never writes to the global temp directory.
                request._form = form
                return await original(request)
            except MultiPartException:
                raise APIError(400, "bad_request", "Malformed or unsupported multipart upload.") from None
            finally:
                with anyio.CancelScope(shield=True):
                    try:
                        if form is not None:
                            await form.close()
                    finally:
                        # Also covers partial parsing, missing fields, invalid
                        # dependencies and cancellation before an endpoint runs.
                        if upload is not None:
                            await run_in_threadpool(upload.close)

        return handle
