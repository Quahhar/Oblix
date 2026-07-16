import os
import uuid
import aiofiles
from pathlib import Path
from fastapi import UploadFile
from app.config import settings


class FileTooLargeError(Exception):
    """Raised when an upload exceeds the configured size limit."""


class LocalStorage:
    """Local filesystem storage. Swap this for S3Storage later via strategy pattern."""

    def __init__(self, base_dir: str = settings.UPLOAD_DIR):
        self.base_dir = Path(base_dir)
        self.base_dir.mkdir(parents=True, exist_ok=True)

    def _get_user_dir(self, user_id: str) -> Path:
        user_dir = self.base_dir / user_id
        user_dir.mkdir(parents=True, exist_ok=True)
        return user_dir

    async def upload(self, user_id: str, file: UploadFile) -> tuple[str, str, int]:
        """
        Save file to disk.
        Returns (storage_path, generated_filename, file_size_bytes).
        """
        user_dir = self._get_user_dir(user_id)
        ext = Path(file.filename).suffix if file.filename else ""
        generated_name = f"{uuid.uuid4().hex}{ext}"
        file_path = user_dir / generated_name

        max_bytes = settings.MAX_UPLOAD_SIZE_MB * 1024 * 1024
        size_bytes = 0
        try:
            async with aiofiles.open(file_path, "wb") as f:
                while chunk := await file.read(1024 * 1024):  # 1MB chunks
                    size_bytes += len(chunk)
                    if size_bytes > max_bytes:
                        raise FileTooLargeError(
                            f"File exceeds the {settings.MAX_UPLOAD_SIZE_MB} MB limit"
                        )
                    await f.write(chunk)
        except FileTooLargeError:
            # Don't leave a partial file behind.
            if file_path.exists():
                os.remove(file_path)
            raise

        storage_path = f"{user_id}/{generated_name}"
        return storage_path, generated_name, size_bytes

    async def save_bytes(self, user_id: str, data: bytes, ext: str = "") -> tuple[str, str, int]:
        """Persist an in-memory blob (used by the .enex/.oblix importers).

        Mirrors upload(): returns (storage_path, generated_filename, size_bytes)
        and enforces the same size ceiling.
        """
        max_bytes = settings.MAX_UPLOAD_SIZE_MB * 1024 * 1024
        if len(data) > max_bytes:
            raise FileTooLargeError(
                f"File exceeds the {settings.MAX_UPLOAD_SIZE_MB} MB limit"
            )
        user_dir = self._get_user_dir(user_id)
        generated_name = f"{uuid.uuid4().hex}{ext}"
        file_path = user_dir / generated_name
        async with aiofiles.open(file_path, "wb") as f:
            await f.write(data)
        return f"{user_id}/{generated_name}", generated_name, len(data)

    async def read_bytes(self, storage_path: str) -> bytes:
        """Read a stored blob into memory (used by the .oblix exporter)."""
        full_path = self.base_dir / storage_path
        async with aiofiles.open(full_path, "rb") as f:
            return await f.read()

    async def download_path(self, storage_path: str) -> Path:
        """Resolve storage_path to absolute filesystem path."""
        full_path = self.base_dir / storage_path
        if not full_path.exists():
            raise FileNotFoundError(f"File not found: {storage_path}")
        return full_path

    async def delete(self, storage_path: str) -> None:
        """Delete a file from storage."""
        full_path = self.base_dir / storage_path
        if full_path.exists():
            os.remove(full_path)

    async def get_size(self, storage_path: str) -> int:
        full_path = self.base_dir / storage_path
        if full_path.exists():
            return full_path.stat().st_size
        return 0


# Singleton
storage = LocalStorage()