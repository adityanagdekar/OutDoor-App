"""Private temporary uploads and crash recovery for macOS/Linux servers."""
import fcntl
import logging
import os
from pathlib import Path
import re
import stat
import tempfile
import time

import anyio
from starlette.concurrency import run_in_threadpool


logger = logging.getLogger("outdoor.api")
_OWNED_NAME = re.compile(r"outdoor-image-[a-z0-9_]{8}\.tmp\Z")


class PrivateImageFile:
    def __init__(self, raw):
        self.raw = raw
        self.path = Path(raw.name)

    def __getattr__(self, name):
        return getattr(self.raw, name)

    def close(self):
        if self.raw.closed:
            return
        try:
            # Unlink while the descriptor is still locked. The cleanup worker
            # cannot mistake a live upload for an abandoned file.
            self.path.unlink(missing_ok=True)
        except OSError:
            # A failed unlink remains eligible for the next cleanup sweep.
            logger.error("temporary_image_delete_failed")
        finally:
            self.raw.close()


class TemporaryImageStore:
    def __init__(self, settings):
        self.directory = settings.temp_image_directory.absolute()
        self.max_age = settings.temp_max_age_seconds
        self.interval = min(settings.temp_cleanup_interval_seconds, self.max_age)

    def initialize(self):
        self.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        info = self.directory.lstat()
        if (
            not stat.S_ISDIR(info.st_mode)
            or info.st_uid != os.geteuid()
            or stat.S_IMODE(info.st_mode) != 0o700
        ):
            # Fail closed instead of changing permissions on a user-selected
            # existing/shared directory or accepting a symlink as the root.
            raise RuntimeError("Temporary image directory must be owned by the server user with permissions 0700.")
        self.cleanup()

    def create(self):
        # mkstemp/NamedTemporaryFile creates an exclusive random name, mode 0600.
        raw = tempfile.NamedTemporaryFile(
            mode="w+b", prefix="outdoor-image-", suffix=".tmp",
            dir=self.directory, delete=False,
        )
        result = PrivateImageFile(raw)
        try:
            fcntl.flock(raw.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            return result
        except BaseException:
            result.close()
            raise

    def cleanup(self):
        cutoff = time.time() - self.max_age
        with os.scandir(self.directory) as entries:
            for entry in entries:
                if not _OWNED_NAME.fullmatch(entry.name):
                    continue
                descriptor = None
                try:
                    # Never follow symlinks, recurse into folders, or delete
                    # unrelated files. Kernel locks also protect other workers.
                    descriptor = os.open(entry.path, os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK)
                    info = os.fstat(descriptor)
                    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mtime > cutoff:
                        continue
                    fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    current = os.stat(entry.path, follow_symlinks=False)
                    if (current.st_dev, current.st_ino) == (info.st_dev, info.st_ino):
                        os.unlink(entry.path)
                except (FileNotFoundError, BlockingIOError):
                    # Another sweep removed it, or an upload still owns it.
                    continue
                except OSError:
                    logger.error("temporary_image_cleanup_failed")
                finally:
                    if descriptor is not None:
                        os.close(descriptor)

    async def run_cleanup(self):
        while True:
            await anyio.sleep(self.interval)
            try:
                await run_in_threadpool(self.cleanup)
            except OSError:
                logger.error("temporary_image_cleanup_failed")
