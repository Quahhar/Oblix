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
    this.skippedAttachments = 0,
  });
}

/// The result of parsing an import file: the notes to create, plus a summary
/// the UI can show before/after applying.
class ImportBundle {
  final List<ImportedNote> notes;

  /// Notebook names the bundle references, in a stable order (so the service
  /// can pre-create them and the UI can report how many).
  final List<String> notebookNames;

  const ImportBundle(this.notes, {this.notebookNames = const []});

  int get noteCount => notes.length;
  int get skippedAttachments =>
      notes.fold(0, (sum, n) => sum + n.skippedAttachments);

  bool get isEmpty => notes.isEmpty;
}
