"""Note import & export: the .oblix archive format and .enex (Evernote) import.

The .oblix format is a ZIP archive:
    manifest.json   {format:"oblix", version:1, exported_at, app, counts}
    notes.json      [ {id,title,content,content_type,is_pinned,is_archived,
                        created_at,updated_at, notebook_path:[...]|null,
                        tags:[name,...], files:[{ref,original_name,mime_type,size_bytes}]} ]
    files/<ref>     raw attachment bytes  (ref = "<file_id><ext>")

Import is transactional at the request level (get_db commits on success). Blobs
written to disk during an import that then fails are unlinked here so a failed
import doesn't leave orphaned files behind.
"""
import io
import os
import re
import json
import base64
import zipfile
import tempfile
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

from defusedxml.ElementTree import fromstring as safe_xml_fromstring
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.config import settings
from app.models.user import User
from app.models.note import Note, NoteVersion, ContentType
from app.models.notebook import Notebook
from app.models.tag import Tag, NoteTag
from app.models.file import File
from app.utils.storage import storage, FileTooLargeError
from app.utils import upload_policy
from app.schemas.transfer import ImportSummary

OBLIX_FORMAT = "oblix"
OBLIX_VERSION = 1
_ENEX_TS = "%Y%m%dT%H%M%SZ"


class TransferService:

    # ------------------------------------------------------------------ export

    async def export_oblix(self, db: AsyncSession, user: User) -> tuple[str, str]:
        """Build an .oblix archive of the user's live notes.

        Returns (temp_file_path, download_filename). The caller streams the file
        and is responsible for unlinking temp_file_path afterwards.
        """
        notebooks = (await db.execute(
            select(Notebook).where(Notebook.user_id == user.id, Notebook.is_deleted == False)  # noqa: E712
        )).scalars().all()
        nb_by_id = {nb.id: nb for nb in notebooks}

        def notebook_path(nb_id) -> Optional[list[str]]:
            path, seen, cur = [], set(), nb_id
            while cur is not None and cur in nb_by_id and cur not in seen:
                seen.add(cur)
                path.append(nb_by_id[cur].name)
                cur = nb_by_id[cur].parent_id
            return list(reversed(path)) or None

        notes = (await db.execute(
            select(Note)
            .where(Note.user_id == user.id, Note.is_deleted == False)  # noqa: E712
            .options(
                selectinload(Note.tags).selectinload(NoteTag.tag),
                selectinload(Note.files),
            )
        )).unique().scalars().all()

        notes_json: list[dict] = []
        warnings: list[str] = []

        tmp = tempfile.NamedTemporaryFile(delete=False, suffix=".oblix")
        tmp.close()
        try:
            # Stream each blob straight into the zip rather than buffering them
            # all in memory first — a power user's attachments could be many GB.
            with zipfile.ZipFile(tmp.name, "w", zipfile.ZIP_DEFLATED) as zf:
                for note in notes:
                    tag_names = [
                        nt.tag.name for nt in note.tags
                        if nt.tag is not None and not nt.tag.is_deleted
                    ]
                    file_entries = []
                    for f in note.files:
                        if f.is_deleted:
                            continue
                        try:
                            data = await storage.read_bytes(f.storage_path)
                        except (FileNotFoundError, OSError):
                            warnings.append(f"Attachment '{f.original_name}' missing on disk; skipped.")
                            continue
                        ext = Path(f.filename).suffix
                        ref = f"{f.id}{ext}"
                        zf.writestr(f"files/{ref}", data)
                        file_entries.append({
                            "ref": ref,
                            "original_name": f.original_name,
                            "mime_type": f.mime_type,
                            "size_bytes": f.size_bytes,
                        })
                    notes_json.append({
                        "id": str(note.id),
                        "title": note.title,
                        "content": note.content,
                        "content_type": getattr(note.content_type, "value", note.content_type),
                        "is_pinned": note.is_pinned,
                        "is_archived": note.is_archived,
                        "created_at": note.created_at.isoformat() if note.created_at else None,
                        "updated_at": note.updated_at.isoformat() if note.updated_at else None,
                        "notebook_path": notebook_path(note.notebook_id),
                        "tags": tag_names,
                        "files": file_entries,
                    })

                manifest = {
                    "format": OBLIX_FORMAT,
                    "version": OBLIX_VERSION,
                    "app": settings.APP_NAME,
                    "exported_at": datetime.now(timezone.utc).isoformat(),
                    "note_count": len(notes_json),
                    "file_count": sum(len(n["files"]) for n in notes_json),
                    "warnings": warnings,
                }
                zf.writestr("manifest.json", json.dumps(manifest, indent=2))
                zf.writestr("notes.json", json.dumps(notes_json, indent=2))
        except Exception:
            if os.path.exists(tmp.name):
                os.remove(tmp.name)
            raise

        stamp = datetime.now(timezone.utc).strftime("%Y%m%d")
        return tmp.name, f"oblix-export-{stamp}.oblix"

    # ------------------------------------------------------------ import .oblix

    async def import_oblix(self, db: AsyncSession, user: User, data: bytes) -> ImportSummary:
        summary = ImportSummary()
        written: list[str] = []
        try:
            try:
                zf = zipfile.ZipFile(io.BytesIO(data))
            except zipfile.BadZipFile:
                raise _BadImport("Not a valid .oblix archive (bad ZIP).")

            meta_cap = settings.MAX_IMPORT_SIZE_MB * 1024 * 1024
            try:
                manifest = json.loads(self._read_member(zf, "manifest.json", meta_cap))
                notes_json = json.loads(self._read_member(zf, "notes.json", meta_cap))
            except KeyError:
                raise _BadImport("Archive is missing manifest.json or notes.json.")
            except _MemberTooLarge:
                raise _BadImport("Archive metadata is implausibly large.")
            except json.JSONDecodeError:
                raise _BadImport("Archive contains malformed JSON.")

            if not isinstance(manifest, dict):
                raise _BadImport("manifest.json must be a JSON object.")
            if manifest.get("format") != OBLIX_FORMAT:
                raise _BadImport("Not an Oblix archive.")
            try:
                archive_version = int(manifest.get("version", 0))
            except (TypeError, ValueError):
                raise _BadImport("manifest.json has an invalid version.")
            if archive_version > OBLIX_VERSION:
                raise _BadImport("Archive was created by a newer version of Oblix.")
            if not isinstance(notes_json, list):
                raise _BadImport("notes.json must be a list of notes.")

            nb_cache: dict[tuple[str, ...], Optional[uuid.UUID]] = {}
            tag_cache: dict[str, uuid.UUID] = {}

            for entry in notes_json:
                if not isinstance(entry, dict):
                    summary.skipped_notes += 1
                    continue
                nb_id = await self._notebook_for_path(
                    db, user, entry.get("notebook_path"), nb_cache
                )
                try:
                    ctype = ContentType(entry.get("content_type", "plain"))
                except ValueError:
                    ctype = ContentType.PLAIN

                note = self._new_note(
                    db,
                    user=user,
                    title=(entry.get("title") or "Untitled")[:500],
                    content=entry.get("content") or "",
                    content_type=ctype,
                    notebook_id=nb_id,
                    is_pinned=bool(entry.get("is_pinned")),
                    is_archived=bool(entry.get("is_archived")),
                    created_at=_parse_iso(entry.get("created_at")),
                    updated_at=_parse_iso(entry.get("updated_at")),
                )
                summary.imported_notes += 1

                await self._attach_tags(db, user, note, entry.get("tags") or [], tag_cache, summary)

                for fref in (entry.get("files") or []):
                    if not isinstance(fref, dict):
                        continue
                    ref = fref.get("ref")
                    original_name = fref.get("original_name") or "attachment"
                    mime = fref.get("mime_type") or "application/octet-stream"
                    if not ref:
                        summary.skipped_files += 1
                        continue
                    # No allowlist filtering here: an .oblix archive is Oblix's
                    # own backup, so every attachment in it was already accepted
                    # when first uploaded. Re-filtering would silently drop a
                    # user's restored files (e.g. an audio memo stored before
                    # the allowlist existed) — data loss on restore.
                    try:
                        blob = self._read_member(
                            zf, f"files/{ref}", settings.MAX_UPLOAD_SIZE_MB * 1024 * 1024
                        )
                    except KeyError:
                        summary.skipped_files += 1
                        summary.warnings.append(f"Attachment '{original_name}' not found in archive.")
                        continue
                    except _MemberTooLarge:
                        summary.skipped_files += 1
                        summary.warnings.append(f"Attachment '{original_name}' exceeds the size limit; skipped.")
                        continue
                    await self._store_attachment(
                        db, user, note, blob, original_name, mime, written, summary
                    )

            await db.flush()
            return summary
        except Exception:
            for sp in written:
                await storage.delete(sp)
            raise

    # ------------------------------------------------------------- import .enex

    async def import_enex(
        self, db: AsyncSession, user: User, data: bytes, notebook_id: uuid.UUID
    ) -> ImportSummary:
        summary = ImportSummary(notebook_id=notebook_id)
        written: list[str] = []
        try:
            try:
                root = safe_xml_fromstring(data)
            except Exception:
                raise _BadImport("File is not valid XML / not a valid .enex export.")

            notes_el = root.findall("note") if root.tag == "en-export" else root.findall(".//note")
            if not notes_el:
                raise _BadImport("No notes found in the .enex file.")

            tag_cache: dict[str, uuid.UUID] = {}

            for note_el in notes_el:
                title = (note_el.findtext("title") or "Untitled").strip()[:500] or "Untitled"
                content = _extract_enml(note_el.findtext("content") or "")
                created = _parse_enex_ts(note_el.findtext("created"))
                updated = _parse_enex_ts(note_el.findtext("updated"))

                note = self._new_note(
                    db,
                    user=user,
                    title=title,
                    content=content,
                    content_type=ContentType.RICH,
                    notebook_id=notebook_id,
                    is_pinned=False,
                    is_archived=False,
                    created_at=created,
                    updated_at=updated,
                )
                summary.imported_notes += 1

                tag_names = [(t.text or "").strip() for t in note_el.findall("tag")]
                await self._attach_tags(db, user, note, tag_names, tag_cache, summary)

                for res in note_el.findall("resource"):
                    self_mime = (res.findtext("mime") or "application/octet-stream").strip()
                    fname = res.findtext("resource-attributes/file-name") or "attachment"
                    b64 = res.findtext("data") or ""
                    if not b64.strip():
                        summary.skipped_files += 1
                        continue
                    if not upload_policy.is_allowed(fname, self_mime):
                        summary.skipped_files += 1
                        continue
                    try:
                        blob = base64.b64decode("".join(b64.split()))
                    except (ValueError, base64.binascii.Error):
                        summary.skipped_files += 1
                        summary.warnings.append(f"Attachment '{fname}' had undecodable data; skipped.")
                        continue
                    await self._store_attachment(
                        db, user, note, blob, fname, self_mime, written, summary
                    )

            await db.flush()
            return summary
        except Exception:
            for sp in written:
                await storage.delete(sp)
            raise

    # ----------------------------------------------------------------- helpers

    def _new_note(self, db, *, user, title, content, content_type, notebook_id,
                  is_pinned, is_archived, created_at, updated_at) -> Note:
        note = Note(
            id=uuid.uuid4(),
            user_id=user.id,
            notebook_id=notebook_id,
            title=title,
            content=content,
            content_type=content_type,
            is_pinned=is_pinned,
            is_archived=is_archived,
        )
        if created_at:
            note.created_at = created_at
        if updated_at:
            note.updated_at = updated_at
        db.add(note)
        # Seed version history so the imported note behaves like any other. Add
        # the NoteVersion row directly rather than via note.versions.append():
        # note.versions is a lazy relationship (lazy="noload"), so appending
        # can't be relied on to persist the row and, on a persistent note, would
        # risk an async lazy-load. The unit of work inserts the note before the
        # version (FK dependency), so setting note_id here is safe.
        db.add(NoteVersion(
            id=uuid.uuid4(),
            note_id=note.id,
            title=title,
            content=content,
            content_type=content_type,
            version_number=1,
        ))
        return note

    async def _notebook_for_path(
        self, db, user, path, cache: dict
    ) -> Optional[uuid.UUID]:
        """Get-or-create the notebook chain for a path like ["Work","Trips"]."""
        if not path or not isinstance(path, list):
            return None
        names = [str(p)[:255] for p in path if str(p).strip()]
        if not names:
            return None
        key = tuple(names)
        if key in cache:
            return cache[key]

        parent_id: Optional[uuid.UUID] = None
        for depth in range(len(names)):
            subkey = tuple(names[: depth + 1])
            if subkey in cache:
                parent_id = cache[subkey]
                continue
            name = names[depth]
            existing = (await db.execute(
                select(Notebook).where(
                    Notebook.user_id == user.id,
                    Notebook.name == name,
                    Notebook.parent_id == parent_id,
                    Notebook.is_deleted == False,  # noqa: E712
                )
            )).scalars().first()
            if existing is None:
                existing = Notebook(id=uuid.uuid4(), user_id=user.id, name=name, parent_id=parent_id)
                db.add(existing)
                await db.flush()
            parent_id = existing.id
            cache[subkey] = parent_id
        return parent_id

    async def _attach_tags(self, db, user, note: Note, names, cache: dict, summary: ImportSummary):
        seen: set[uuid.UUID] = set()
        for raw in names:
            name = (raw or "").strip()[:128]
            if not name:
                continue
            tag_id = cache.get(name)
            if tag_id is None:
                tag_id = await self._get_or_create_tag(db, user, name)
                cache[name] = tag_id
                summary.imported_tags += 1
            if tag_id not in seen:
                seen.add(tag_id)
                # Add the association row directly rather than appending to the
                # lazy `note.tags` collection: on a persistent note that append
                # would trigger a lazy-load -> MissingGreenlet in async.
                db.add(NoteTag(note_id=note.id, tag_id=tag_id))

    async def _get_or_create_tag(self, db, user, name: str) -> uuid.UUID:
        existing = (await db.execute(
            select(Tag).where(Tag.user_id == user.id, Tag.name == name)
        )).scalars().first()
        if existing is not None:
            if existing.is_deleted:
                existing.is_deleted = False
                existing.deleted_at = None
            return existing.id
        tag = Tag(id=uuid.uuid4(), user_id=user.id, name=name)
        db.add(tag)
        await db.flush()
        return tag.id

    async def _store_attachment(self, db, user, note: Note, blob: bytes,
                                original_name: str, mime: str,
                                written: list, summary: ImportSummary):
        ext = Path(original_name).suffix
        try:
            storage_path, generated_name, size_bytes = await storage.save_bytes(
                str(user.id), blob, ext
            )
        except FileTooLargeError:
            summary.skipped_files += 1
            summary.warnings.append(f"Attachment '{original_name}' exceeds the size limit; skipped.")
            return
        written.append(storage_path)
        db.add(File(
            id=uuid.uuid4(),
            user_id=user.id,
            note_id=note.id,
            filename=generated_name,
            original_name=original_name[:500],
            mime_type=mime[:255],
            size_bytes=size_bytes,
            storage_path=storage_path,
        ))
        summary.imported_files += 1

    def _read_member(self, zf: zipfile.ZipFile, name: str, max_bytes: int) -> bytes:
        """Read one zip member, bounding decompression to defuse zip bombs.

        Unlike summing the central-directory sizes (which a crafted archive can
        under-report), reading a bounded number of *decompressed* bytes caps the
        work regardless of what the header claims. Per-member bounds also let a
        legitimately large export round-trip, which a single total-size cap
        (rejected at MAX_IMPORT_SIZE_MB) would wrongly block.
        """
        with zf.open(name) as fp:  # raises KeyError if absent
            data = fp.read(max_bytes + 1)
        if len(data) > max_bytes:
            raise _MemberTooLarge(name)
        return data


class _BadImport(Exception):
    """Signals a client-side bad import (mapped to HTTP 400 in the router)."""


class _MemberTooLarge(Exception):
    """A single archive member exceeded its allowed decompressed size."""


def _parse_iso(value) -> Optional[datetime]:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value)
    except (ValueError, TypeError):
        return None


def _parse_enex_ts(value) -> Optional[datetime]:
    if not value:
        return None
    try:
        return datetime.strptime(value.strip(), _ENEX_TS).replace(tzinfo=timezone.utc)
    except (ValueError, TypeError):
        return None


_EN_NOTE_OPEN = re.compile(r"<en-note\b[^>]*>", re.IGNORECASE)
_XML_PROLOG = re.compile(r"^\s*<\?xml\b[^>]*\?>", re.IGNORECASE)
_DOCTYPE = re.compile(r"^\s*<!DOCTYPE\b[^>]*>", re.IGNORECASE)


def _extract_enml(raw: str) -> str:
    """Return the inner body of an ENML <en-note>, verbatim.

    ENML is an XHTML-ish document wrapped in <en-note>, prefixed by an XML
    prolog and a DOCTYPE. We keep the inner markup as-is (content_type=rich) and
    strip the wrapper WITHOUT XML-parsing it: real Evernote content is full of
    HTML named entities (&nbsp; &mdash; &eacute; &copy; ...) that a strict XML
    parser rejects, which previously forced a fallback that dumped the whole raw
    document — prolog, DOCTYPE and all — into the user's note body.
    """
    if not raw or not raw.strip():
        return ""
    m = _EN_NOTE_OPEN.search(raw)
    if m:
        end = raw.rfind("</en-note>")
        inner = raw[m.end():end] if end != -1 else raw[m.end():]
        return inner.strip()
    # No <en-note> wrapper — best-effort strip of any prolog / DOCTYPE.
    body = _XML_PROLOG.sub("", raw, count=1)
    body = _DOCTYPE.sub("", body, count=1)
    return body.strip()


transfer_service = TransferService()
