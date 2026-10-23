"""Bounded JPEG/PNG processing. Call from a worker, never the event loop."""
from io import BytesIO
from threading import Lock
import warnings

from PIL import Image, ImageOps, UnidentifiedImageError

from .errors import APIError


# Shared by all app instances in this process. Deploy with one server worker.
_processing_lock = Lock()


class ImageProcessor:
    def __init__(self, settings):
        self.settings = settings

    def process(self, data: bytes, content_type: str) -> bytes:
        with _processing_lock, warnings.catch_warnings():
            warnings.simplefilter("error", Image.DecompressionBombWarning)
            try:
                return self._process(data, content_type)
            except (Image.DecompressionBombError, Image.DecompressionBombWarning):
                raise APIError(413, "image_too_many_pixels", "Image exceeds the safe pixel limit.") from None
            except (UnidentifiedImageError, OSError, SyntaxError, ValueError):
                raise APIError(422, "invalid_image", "Image is malformed or truncated.") from None

    def _process(self, data, content_type):
        with BytesIO(data) as source:
            with Image.open(source) as image:
                expected = {"image/jpeg": "JPEG", "image/png": "PNG"}.get(content_type)
                if image.format not in {"JPEG", "PNG"} or image.format != expected:
                    raise APIError(415, "unsupported_image_type", "Submit a JPEG or PNG with a matching media type.")
                if image.width * image.height > self.settings.max_image_pixels:
                    raise APIError(413, "image_too_many_pixels", "Image exceeds the configured pixel limit.")
                if getattr(image, "n_frames", 1) != 1:
                    raise APIError(415, "animated_image", "Submit a single-frame image.")
                # Verify structure before reopening for full pixel decoding.
                image.verify()
            source.seek(0)
            with Image.open(source) as image:
                image.load()  # Truncated-image loading remains disabled.
                with ImageOps.exif_transpose(image) as oriented:
                    oriented.thumbnail(
                        (self.settings.image_max_dimension,) * 2,
                        Image.Resampling.LANCZOS,
                    )
                    # A fresh RGB canvas prevents EXIF/GPS, comments, ICC and
                    # other input metadata from reaching the encoded image.
                    with Image.new("RGB", oriented.size, "white") as clean:
                        if oriented.mode in {"RGBA", "LA"} or "transparency" in oriented.info:
                            with oriented.convert("RGBA") as rgba:
                                with rgba.getchannel("A") as alpha:
                                    clean.paste(rgba, mask=alpha)
                        else:
                            with oriented.convert("RGB") as rgb:
                                clean.paste(rgb)
                        with BytesIO() as output:
                            clean.save(output, format="JPEG", quality=self.settings.image_jpeg_quality)
                            return output.getvalue()
