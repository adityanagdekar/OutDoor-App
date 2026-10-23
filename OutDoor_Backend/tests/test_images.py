from concurrent.futures import ThreadPoolExecutor
from io import BytesIO
from threading import Event
from types import SimpleNamespace

import pytest
from PIL import Image

from app.errors import APIError
from app.images import ImageProcessor


def image_bytes(mode="RGB", size=(80, 40), format="PNG", **save_options):
    with Image.new(mode, size, "red") as image, BytesIO() as stream:
        image.save(stream, format=format, **save_options)
        return stream.getvalue()


@pytest.fixture
def processor():
    return ImageProcessor(SimpleNamespace(max_image_pixels=20_000_000, image_max_dimension=60, image_jpeg_quality=80))


@pytest.mark.parametrize("mode", ["RGB", "RGBA", "P", "L", "LA"])
def test_output_is_resized_metadata_free_jpeg(processor, mode):
    # Use a numeric color for modes without named-color support.
    with Image.new(mode, (80, 40)) as image, BytesIO() as stream:
        image.save(stream, format="PNG")
        result = processor.process(stream.getvalue(), "image/png")
    with Image.open(BytesIO(result)) as output:
        assert output.format == "JPEG"
        assert output.mode == "RGB"
        assert output.size == (60, 30)
        assert not output.getexif()
        assert not {"exif", "icc_profile", "comment", "transparency"} & output.info.keys()


def test_exif_orientation_and_metadata_stripping(processor):
    exif = Image.Exif()
    exif[274] = 6
    exif[270] = "private description"
    result = processor.process(image_bytes(format="JPEG", exif=exif), "image/jpeg")
    with Image.open(BytesIO(result)) as image:
        assert image.size == (30, 60)
        assert not image.getexif()


def test_alpha_is_composited_on_white_without_upscaling(processor):
    with Image.new("RGBA", (10, 10), (0, 0, 0, 0)) as image, BytesIO() as stream:
        image.save(stream, format="PNG")
        result = processor.process(stream.getvalue(), "image/png")
    with Image.open(BytesIO(result)) as output:
        assert output.size == (10, 10)
        assert output.getpixel((0, 0)) == (255, 255, 255)


def test_pixel_limit_precedes_decode(processor, monkeypatch):
    data = image_bytes(size=(100, 100))
    processor.settings.max_image_pixels = 9999
    def unexpected_load(*args, **kwargs):
        pytest.fail("Full decoding must not run for excessive dimensions")
    monkeypatch.setattr(Image.Image, "load", unexpected_load)
    with pytest.raises(APIError) as error:
        processor.process(data, "image/png")
    assert error.value.status == 413


@pytest.mark.parametrize("data, mime, status", [
    (b"not an image", "image/png", 422),
    (image_bytes()[:40], "image/png", 422),
    (image_bytes(format="JPEG")[:-20], "image/jpeg", 422),
    (image_bytes(), "image/jpeg", 415),
    (image_bytes(format="GIF"), "image/png", 415),
])
def test_invalid_images(processor, data, mime, status):
    with pytest.raises(APIError) as error:
        processor.process(data, mime)
    assert error.value.status == status


def test_processing_is_serial_across_instances(processor, monkeypatch):
    entered, release, second_entered = Event(), Event(), Event()
    other = ImageProcessor(processor.settings)
    def slow(*args):
        entered.set()
        assert release.wait(5)
        return b"first"
    def second(*args):
        second_entered.set()
        return b"second"
    monkeypatch.setattr(processor, "_process", slow)
    monkeypatch.setattr(other, "_process", second)
    with ThreadPoolExecutor(2) as pool:
        first = pool.submit(processor.process, b"", "image/png")
        assert entered.wait(5)
        following = pool.submit(other.process, b"", "image/png")
        try:
            assert not second_entered.wait(0.1)
        finally:
            release.set()
        assert first.result() == b"first"
        assert following.result() == b"second"


def test_animated_png_rejected(processor):
    with Image.new("RGB", (4, 4), "red") as first, Image.new("RGB", (4, 4), "blue") as second, BytesIO() as stream:
        first.save(stream, format="PNG", save_all=True, append_images=[second])
        with pytest.raises(APIError) as error:
            processor.process(stream.getvalue(), "image/png")
    assert error.value.code == "animated_image"
