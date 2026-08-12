import 'package:uuid/uuid.dart';
import '../../core/db/app_database.dart';
import '../../core/db/meta_dao.dart';
import '../../data/io/enex_parser.dart';
import '../../data/io/epub_exporter.dart';
import '../../data/io/epub_importer.dart';
import '../../data/io/import_models.dart';
import '../../data/io/markdown_exporter.dart';
import '../../data/io/markdown_importer.dart';
import '../../data/io/oblix_archive.dart';
import '../../data/io/text_exporter.dart';
import '../../data/models/note.dart';
import '../../data/models/notebook.dart';
import '../../data/models/tag.dart';
import '../../data/repositories/attachment_repository.dart';
import '../../data/repositories/note_repository.dart';
import '../../data/repositories/notebook_repository.dart';
import '../../data/repositories/tag_repository.dart';
import '../../core/native/oblix_core.dart';

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

  static const empty = ImportResult(
    notesImported: 0,
    notebooksCreated: 0,
    skippedAttachments: 0,
  );

  ImportResult operator +(ImportResult other) => ImportResult(
    notesImported: notesImported + other.notesImported,
    notebooksCreated: notebooksCreated + other.notebooksCreated,
    skippedAttachments: skippedAttachments + other.skippedAttachments,
  );
}

/// Raised when a native export cannot include every attachment belonging to
/// the selected notes.
///
/// A partial `.oblix` archive would look successful while silently losing
/// files. Native export therefore fails as a unit and lets the UI tell the
/// user which attachment bytes must be made available first.
class OblixExportException implements Exception {
  final List<String> unavailableAttachments;

  OblixExportException(Iterable<String> unavailableAttachments)
    : unavailableAttachments = List.unmodifiable(unavailableAttachments);

  @override
  String toString() {
    final count = unavailableAttachments.length;
    final noun = count == 1 ? 'attachment is' : 'attachments are';
    final preview = unavailableAttachments.take(3).join(', ');
    final remainder = count > 3 ? ' and ${count - 3} more' : '';
    return 'Cannot create a complete .oblix export: $count $noun '
        'unavailable ($preview$remainder). Make the files available and try '
        'again.';
  }
}

/// Imports `.enex`/`.oblix`/`.md`/`.txt`/`.epub` files into the local store
/// (as new notes that then sync), and exports to `.oblix`/`.md`/`.txt`/`.epub`.
///
/// Import always creates **new** notes with fresh ids on the current account —
/// so importing never collides with existing data or another user's ids. (A
/// consequence: re-importing your own export duplicates it. A future "restore"
/// mode could merge by id instead.)
class ImportExportService {
  final NoteRepository _notes;
  final NotebookRepository _notebooks;
  final TagRepository _tags;
  final AttachmentRepository _attachments;
  final MetaDao _meta;
  final Uuid _uuid;

  ImportExportService({
    AppDatabase? appDb,
    NoteRepository? notes,
    NotebookRepository? notebooks,
    TagRepository? tags,
    AttachmentRepository? attachments,
    MetaDao? meta,
    Uuid? uuid,
  }) : _notes = notes ?? NoteRepository(appDb: appDb),
       _notebooks = notebooks ?? NotebookRepository(appDb: appDb),
       _tags = tags ?? TagRepository(appDb: appDb),
       _attachments = attachments ?? AttachmentRepository(appDb: appDb),
       _meta = meta ?? MetaDao(appDb ?? AppDatabase.instance),
       _uuid = uuid ?? const Uuid();

  // --- Import ---

  Future<ImportResult> importEnex(String xml, {String? notebookName}) =>
      _apply(EnexParser.parse(xml, notebookName: notebookName));

  Future<ImportResult> importOblix(List<int> bytes) =>
      _apply(OblixArchive.decode(bytes));

  /// Import one or more `.md` / `.txt` files. Each file becomes a note.
  Future<ImportResult> importMarkdownFiles(
    List<(String name, List<int> bytes)> files,
  ) async {
    return _apply(MarkdownImporter.parseMany(files));
  }

  /// Import an EPUB file — each spine chapter becomes a note, grouped under
  /// a notebook named after the book's dc:title.
  Future<ImportResult> importEpub(List<int> bytes) async {
    return _apply(EpubImporter.parse(bytes));
  }

  Future<ImportResult> _apply(ImportBundle bundle) async {
    if (bundle.isEmpty) return ImportResult.empty;
    final userId = await _meta.getUserId() ?? '';

    // Resolve notebooks by their complete root-to-leaf path. A leaf-name map
    // corrupts valid structures such as Work/Projects + Personal/Projects by
    // linking both notes to whichever "Projects" happened to be seen first.
    final existing = await _notebooks.listNotebooks();
    final idByPath = _indexNotebookPaths(existing);

    var notebooksCreated = 0;

    // v1/foreign imports with a flat notebook name have no parent metadata, so
    // they resolve explicitly at the root rather than matching a nested leaf.
    final wantedPaths = <List<String>>[
      for (final name in bundle.notebookNames)
        if (name.isNotEmpty) [name],
      ...bundle.notebookPaths,
      for (final n in bundle.notes)
        if (n.notebookPath != null && n.notebookPath!.isNotEmpty)
          n.notebookPath!
        else if (n.notebookName != null && n.notebookName!.isNotEmpty)
          [n.notebookName!],
    ];
    for (final path in wantedPaths) {
      await _ensureNotebookPath(path, idByPath, (_) => notebooksCreated++);
    }

    // Notes carry tag names, but the app's tag browser reads the separate tag
    // catalog. Materialize missing catalog rows so an imported tag is not
    // present on a note yet mysteriously absent everywhere else in the UI.
    final existingTagNames = {
      for (final tag in await _tags.listTags()) tag.name,
    };
    for (final note in bundle.notes) {
      for (final tagName in note.tagNames) {
        if (tagName.isNotEmpty && existingTagNames.add(tagName)) {
          await _tags.createTag(tagName);
        }
      }
    }

    final now = DateTime.now().toUtc();
    // Map to store minted note ids for attachment wiring.
    final noteIdForIndex = <int, String>{};
    final notes = <Note>[
      for (var i = 0; i < bundle.notes.length; i++)
        _buildNote(bundle.notes[i], i, userId, idByPath, now, noteIdForIndex),
    ];
    await _notes.importNotes(notes);

    // Wire attachments (best-effort).
    var skippedAttachments = bundle.skippedAttachments;
    for (var i = 0; i < bundle.notes.length; i++) {
      final imported = bundle.notes[i];
      final noteId = noteIdForIndex[i];
      if (noteId == null || imported.attachments.isEmpty) continue;
      for (final a in imported.attachments) {
        try {
          await _attachments.attach(
            noteId: noteId,
            bytes: a.bytes,
            originalName: a.originalName,
            mimeType: a.mimeType,
          );
        } catch (_) {
          skippedAttachments++;
        }
      }
    }

    return ImportResult(
      notesImported: notes.length,
      notebooksCreated: notebooksCreated,
      skippedAttachments: skippedAttachments,
    );
  }

  Note _buildNote(
    ImportedNote n,
    int index,
    String userId,
    Map<String, String> idByPath,
    DateTime now,
    Map<int, String> noteIdForIndex,
  ) {
    final id = _uuid.v4();
    noteIdForIndex[index] = id;

    String? notebookId;
    // notebookPath takes precedence over notebookName.
    if (n.notebookPath != null && n.notebookPath!.isNotEmpty) {
      notebookId = idByPath[_pathKey(n.notebookPath!)];
    } else if (n.notebookName != null && n.notebookName!.isNotEmpty) {
      notebookId = idByPath[_pathKey([n.notebookName!])];
    }

    return Note(
      id: id,
      userId: userId,
      notebookId: notebookId,
      title: n.title,
      content: n.content,
      contentType: n.contentType,
      isPinned: n.isPinned,
      isArchived: n.isArchived,
      createdAt: n.createdAt,
      // Never let a bogus future timestamp win LWW forever.
      updatedAt: DateTime.fromMicrosecondsSinceEpoch(
        clampImportedTimestampMicros(
          timestampMicrosUtc: n.updatedAt.toUtc().microsecondsSinceEpoch,
          nowMicrosUtc: now.microsecondsSinceEpoch,
        ),
        isUtc: true,
      ),
      tagNames: n.tagNames,
    );
  }

  /// Walk a path of notebook names (e.g. ["Work", "Projects"]), creating
  /// any missing notebooks along the way. [onCreated] is called for each
  /// new notebook so callers can track counts.
  Future<void> _ensureNotebookPath(
    List<String> path,
    Map<String, String> idByPath,
    void Function(Notebook nb) onCreated,
  ) async {
    if (path.isEmpty) return;
    String? parentId;
    final walked = <String>[];
    for (final name in path) {
      if (name.isEmpty) continue;
      walked.add(name);
      final key = _pathKey(walked);
      final existingId = idByPath[key];
      if (existingId != null) {
        parentId = existingId;
        continue;
      }
      final nb = await _notebooks.createNotebook(
        name: name,
        parentId: parentId,
      );
      idByPath[key] = nb.id;
      parentId = nb.id;
      onCreated(nb);
    }
  }

  /// Index existing notebooks without assuming leaf names are globally unique.
  /// Broken parent links and cycles are treated as roots; imports must remain
  /// usable even if an older local database contains malformed hierarchy data.
  Map<String, String> _indexNotebookPaths(List<Notebook> notebooks) {
    final result = <String, String>{};
    final resolved = resolveNotebookPaths([
      for (final notebook in notebooks)
        (id: notebook.id, name: notebook.name, parentId: notebook.parentId),
    ]);
    for (final path in resolved) {
      result.putIfAbsent(path.pathKey, () => path.id);
    }
    return result;
  }

  /// Length-prefix each component so names containing separators cannot make
  /// two different paths share a lookup key.
  String _pathKey(List<String> path) => notebookPathKey(path);

  // --- Export ---

  /// Notes the user can choose from in the export UI.
  Future<List<Note>> listExportableNotes() =>
      _notes.listNotes(archived: null, deleted: false);

  /// Serialize every live local note plus all live notebook/tag catalog
  /// metadata to `.oblix` bytes. Trash is excluded; archived notes are
  /// included. This legacy whole-account API keeps empty notebooks and unused
  /// tags in the archive, unlike the selective export used by the UI.
  Future<List<int>> exportOblix() async {
    final notes = await _notes.listNotes(archived: null, deleted: false);
    return _encodeOblix(
      notes: notes,
      notebooks: await _notebooks.listNotebooks(),
      tags: await _tags.listTags(),
    );
  }

  /// Serialize only [notes] and the notebook/tag metadata they reference.
  /// Attachment bytes belonging to unselected notes are never read.
  Future<List<int>> exportNotesOblix(List<Note> notes) async {
    if (notes.isEmpty) {
      throw ArgumentError.value(notes, 'notes', 'Choose at least one note');
    }

    // Keep caller order while preventing a duplicated selection from producing
    // duplicate note records or attachment blobs in the archive.
    final selectedNotes = <Note>[];
    final selectedIds = <String>{};
    for (final note in notes) {
      if (selectedIds.add(note.id)) selectedNotes.add(note);
    }

    final allNotebooks = await _notebooks.listNotebooks();
    final notebookIds = selectExportNotebookIds(
      noteNotebookIds: selectedNotes.map((note) => note.notebookId).nonNulls,
      notebooks: [
        for (final notebook in allNotebooks)
          (id: notebook.id, name: notebook.name, parentId: notebook.parentId),
      ],
    ).toSet();
    final notebooks = [
      for (final notebook in allNotebooks)
        if (notebookIds.contains(notebook.id)) notebook,
    ];

    final wantedTagNames = {for (final note in selectedNotes) ...note.tagNames};
    final tags = [
      for (final tag in await _tags.listTags())
        if (wantedTagNames.contains(tag.name)) tag,
    ];

    return _encodeOblix(notes: selectedNotes, notebooks: notebooks, tags: tags);
  }

  Future<List<int>> _encodeOblix({
    required List<Note> notes,
    required List<Notebook> notebooks,
    required List<Tag> tags,
  }) async {
    // Gather attachments per note. A native export succeeds only if every
    // attachment currently known for these notes can be read in full.
    final attachmentsByNoteId = <String, List<OblixAttachment>>{};
    final unavailableAttachments = <String>[];
    for (final note in notes) {
      final atts = await _attachments.listForNote(note.id);
      final oblixAtts = <OblixAttachment>[];
      for (final a in atts) {
        List<int>? bytes;
        try {
          bytes = await _attachments.bytesFor(a);
        } catch (_) {
          // The common case is a remote-only file while offline. Do not expose
          // transport details, but do report that this archive is incomplete.
        }
        if (bytes == null || (a.sizeBytes > 0 && bytes.length != a.sizeBytes)) {
          unavailableAttachments.add('${note.title} / ${a.originalName}');
          continue;
        }
        oblixAtts.add(
          OblixAttachment(
            id: a.id,
            originalName: a.originalName,
            mimeType: a.mimeType,
            bytes: bytes,
          ),
        );
      }
      if (oblixAtts.isNotEmpty) attachmentsByNoteId[note.id] = oblixAtts;
    }
    if (unavailableAttachments.isNotEmpty) {
      throw OblixExportException(unavailableAttachments);
    }

    return OblixArchive.encode(
      notes: notes,
      notebooks: notebooks,
      tags: tags,
      attachmentsByNoteId: attachmentsByNoteId,
    );
  }

  /// Export all notes as a single EPUB book.
  Future<List<int>> exportAllEpub() async {
    final notes = await _notes.listNotes(archived: null, deleted: false);
    return exportNotesEpub(notes);
  }

  List<int> exportNotesEpub(List<Note> notes) =>
      EpubExporter.notesToEpub(notes);

  /// Export all notes as a ZIP of Markdown files.
  Future<List<int>> exportAllMarkdownZip() async {
    final notes = await _notes.listNotes(archived: null, deleted: false);
    return exportNotesMarkdownZip(notes);
  }

  List<int> exportNotesMarkdownZip(List<Note> notes) =>
      MarkdownExporter.notesToMarkdownZip(notes);

  /// Export all notes as a ZIP of plain-text files.
  Future<List<int>> exportAllTextZip() async {
    final notes = await _notes.listNotes(archived: null, deleted: false);
    return exportNotesTextZip(notes);
  }

  List<int> exportNotesTextZip(List<Note> notes) =>
      TextExporter.notesToTextZip(notes);

  /// Export a single note as a Markdown string.
  String exportNoteMarkdown(Note note) => MarkdownExporter.noteToMarkdown(note);

  /// Export a single note as a plain-text string.
  String exportNoteText(Note note) => TextExporter.noteToText(note);

  /// Export a single note as `.oblix` bytes (one-note archive).
  Future<List<int>> exportNoteOblix(Note note) => exportNotesOblix([note]);
}
