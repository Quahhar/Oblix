"""What this note-taking app is willing to store.

Oblix is a notes app, not a general file host: attachments are limited to the
kinds of things you paste into a note (images, PDFs, plain-text/markdown).
Every write funnels through here so the accepted set stays in one place.
"""
from pathlib import Path
from typing import Optional

# Primary gate is the filename extension (client-supplied MIME is unreliable);
# a recognised MIME is accepted too, to cover extensionless uploads.
ALLOWED_EXTENSIONS = frozenset({
    ".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic", ".heif",
    ".bmp", ".tif", ".tiff",
    ".pdf",
    ".txt", ".md", ".markdown", ".csv",
})

ALLOWED_MIME_TYPES = frozenset({
    "image/png", "image/jpeg", "image/gif", "image/webp",
    "image/heic", "image/heif", "image/bmp", "image/tiff",
    "application/pdf",
    "text/plain", "text/markdown", "text/csv",
})


def is_allowed(filename: Optional[str], mime_type: Optional[str]) -> bool:
    ext = Path(filename).suffix.lower() if filename else ""
    if ext in ALLOWED_EXTENSIONS:
        return True
    if mime_type and mime_type.split(";", 1)[0].strip().lower() in ALLOWED_MIME_TYPES:
        return True
    return False


def describe_allowed() -> str:
    return "Allowed types: images (PNG/JPEG/GIF/WebP/HEIC/BMP/TIFF), PDF, and text (TXT/Markdown/CSV)."
