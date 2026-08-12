import '../../core/native/crdt_types.dart';

/// A note parsed from an import source (ENEX or .oblix), before it is given a
/// local id/owner and persisted. Import always creates *new* notes on the
/// current account, so ids are deliberately absent here — the service mints
/// them. Timestamps are preserved from the source so history survives.
class ImportedNote {
  final String title;
  final String content;
  final String contentType; // plain | rich | markdown
  final List<String> tagNames;
  final bool isPinned;
  final bool isArchived;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Name of the notebook this note belongs to, if the source expressed one.
  /// The service resolves names to real notebook ids (creating/deduping).
  final String? notebookName;

  /// The note's notebook as a path of names from the root (e.g.
  /// `["Work", "Projects"]`) — how nested notebooks survive a `.oblix`
  /// round-trip. Takes precedence over [notebookName] when present.
  final List<String>? notebookPath;

  /// Attachments the source carried, bytes included, to be stored alongside
  /// the note on import (best-effort — see the service).
  final List<ImportedAttachment> attachments;

  /// Number of embedded attachments the source carried that we could not import
  /// yet (no client attachment support) — surfaced to the user as a count.
  final int skippedAttachments;

  const ImportedNote({
    required this.title,
    required this.content,
    this.contentType = 'plain',
    this.tagNames = const [],
    this.isPinned = false,
    this.isArchived = false,
    required this.createdAt,
    required this.updatedAt,
    this.notebookName,
    this.notebookPath,
    this.attachments = const [],
    this.skippedAttachments = 0,
  });
}

/// One attachment carried by an import source: display name, MIME type and
/// the raw bytes. The service re-caches the bytes locally on import, so no
/// source path/id survives here.
class ImportedAttachment {
  final String originalName;
  final String? mimeType;
  final List<int> bytes;

  const ImportedAttachment({
    required this.originalName,
    this.mimeType,
    required this.bytes,
  });
}

/// The result of parsing an import file: the notes to create, plus a summary
/// the UI can show before/after applying.
class ImportBundle {
  final List<ImportedNote> notes;

  /// Notebook names the bundle references, in a stable order (so the service
  /// can pre-create them and the UI can report how many).
  final List<String> notebookNames;

  /// Nested notebooks the bundle references, each a path of names from the
  /// root — pre-created like [notebookNames] so even empty folders survive.
  final List<List<String>> notebookPaths;

  const ImportBundle(
    this.notes, {
    this.notebookNames = const [],
    this.notebookPaths = const [],
  });

  factory ImportBundle.fromCore(CoreImportBundleValue bundle) => ImportBundle(
    [
      for (final note in bundle.notes)
        ImportedNote(
          title: note.title,
          content: note.content,
          contentType: note.contentType,
          tagNames: note.tagNames,
          isPinned: note.isPinned,
          isArchived: note.isArchived,
          createdAt: DateTime.fromMicrosecondsSinceEpoch(
            note.createdAtMicrosUtc,
            isUtc: true,
          ),
          updatedAt: DateTime.fromMicrosecondsSinceEpoch(
            note.updatedAtMicrosUtc,
            isUtc: true,
          ),
          notebookName: note.notebookName,
          notebookPath: note.notebookPath,
          attachments: [
            for (final attachment in note.attachments)
              ImportedAttachment(
                originalName: attachment.originalName,
                mimeType: attachment.mimeType,
                bytes: attachment.bytes,
              ),
          ],
          skippedAttachments: note.skippedAttachments,
        ),
    ],
    notebookNames: bundle.notebookNames,
    notebookPaths: bundle.notebookPaths,
  );

  int get noteCount => notes.length;
  int get skippedAttachments =>
      notes.fold(0, (sum, n) => sum + n.skippedAttachments);

  bool get isEmpty => notes.isEmpty;
}
