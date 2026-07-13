import 'package:uuid/uuid.dart';
import '../../core/db/app_database.dart';
import '../../core/db/meta_dao.dart';
import '../../data/io/enex_parser.dart';
import '../../data/io/import_models.dart';
import '../../data/io/oblix_archive.dart';
import '../../data/models/note.dart';
import '../../data/repositories/note_repository.dart';
import '../../data/repositories/notebook_repository.dart';
import '../../data/repositories/tag_repository.dart';

/// Summary of an import, shown to the user afterward.
class ImportResult {
  final int notesImported;
  final int notebooksCreated;
  final int skippedAttachments;

  const ImportResult({
    required this.notesImported,
    required this.notebooksCreated,
    required this.skippedAttachments,
  });

  static const empty =
      ImportResult(notesImported: 0, notebooksCreated: 0, skippedAttachments: 0);
}

/// Imports `.enex`/`.oblix` files into the local store (as new notes that then
/// sync), and exports everything to a `.oblix` archive.
///
/// Import always creates **new** notes with fresh ids on the current account —
/// so importing never collides with existing data or another user's ids. (A
/// consequence: re-importing your own export duplicates it. A future "restore"
/// mode could merge by id instead.)
class ImportExportService {
  final NoteRepository _notes;
  final NotebookRepository _notebooks;
  final TagRepository _tags;
  final MetaDao _meta;
  final Uuid _uuid;

  ImportExportService({
    AppDatabase? appDb,
    NoteRepository? notes,
    NotebookRepository? notebooks,
    TagRepository? tags,
    MetaDao? meta,
    Uuid? uuid,
  })  : _notes = notes ?? NoteRepository(appDb: appDb),
        _notebooks = notebooks ?? NotebookRepository(appDb: appDb),
        _tags = tags ?? TagRepository(appDb: appDb),
        _meta = meta ?? MetaDao(appDb ?? AppDatabase.instance),
        _uuid = uuid ?? const Uuid();

  // --- Import ---

  Future<ImportResult> importEnex(String xml, {String? notebookName}) =>
      _apply(EnexParser.parse(xml, notebookName: notebookName));

  Future<ImportResult> importOblix(List<int> bytes) =>
      _apply(OblixArchive.decode(bytes));

  Future<ImportResult> _apply(ImportBundle bundle) async {
    if (bundle.isEmpty) return ImportResult.empty;
    final userId = await _meta.getUserId() ?? '';

    // Resolve notebook names → ids: reuse existing by name, create the rest.
    final existing = await _notebooks.listNotebooks();
    final idByName = {for (final nb in existing) nb.name: nb.id};
    final wantedNames = <String>{
      ...bundle.notebookNames,
      for (final n in bundle.notes)
        if (n.notebookName != null && n.notebookName!.isNotEmpty)
          n.notebookName!,
    };
    var notebooksCreated = 0;
    for (final name in wantedNames) {
      if (!idByName.containsKey(name)) {
        final nb = await _notebooks.createNotebook(name: name);
        idByName[name] = nb.id;
        notebooksCreated++;
      }
    }

    final now = DateTime.now().toUtc();
    final notes = <Note>[
      for (final n in bundle.notes)
        Note(
          id: _uuid.v4(),
          userId: userId,
          notebookId: (n.notebookName == null || n.notebookName!.isEmpty)
              ? null
              : idByName[n.notebookName],
          title: n.title,
          content: n.content,
          contentType: n.contentType,
          isPinned: n.isPinned,
          isArchived: n.isArchived,
          createdAt: n.createdAt,
          // Never let a bogus future timestamp win LWW forever.
          updatedAt: n.updatedAt.isAfter(now) ? now : n.updatedAt,
          tagNames: n.tagNames,
        ),
    ];
    await _notes.importNotes(notes);

    return ImportResult(
      notesImported: notes.length,
      notebooksCreated: notebooksCreated,
      skippedAttachments: bundle.skippedAttachments,
    );
  }

  // --- Export ---

  /// Serialize the whole account (all live notes, notebooks, tags) to `.oblix`
  /// bytes. Trash (soft-deleted) is excluded; archived notes are included.
  Future<List<int>> exportOblix() async {
    final notes = await _notes.listNotes(archived: null, deleted: false);
    final notebooks = await _notebooks.listNotebooks();
    final tags = await _tags.listTags();
    return OblixArchive.encode(
      notes: notes,
      notebooks: notebooks,
      tags: tags,
    );
  }
}
