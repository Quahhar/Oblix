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
import '../../data/repositories/attachment_repository.dart';
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

  static const empty = ImportResult(
    notesImported: 0,
    notebooksCreated: 0,
    skippedAttachments: 0,
  );
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

    // Resolve notebook names → ids: reuse existing by name, create the rest.
    final existing = await _notebooks.listNotebooks();
    final idByName = {for (final nb in existing) nb.name: nb.id};

    var notebooksCreated = 0;

    // Resolve flat notebook names.
    final wantedNames = <String>{
      ...bundle.notebookNames,
      for (final n in bundle.notes)
        if (n.notebookName != null && n.notebookName!.isNotEmpty)
          n.notebookName!,
    };
    for (final name in wantedNames) {
      if (!idByName.containsKey(name)) {
        final nb = await _notebooks.createNotebook(name: name);
        idByName[name] = nb.id;
        notebooksCreated++;
      }
    }

    // Resolve nested notebook paths (e.g. ["Work", "Projects"]).
    for (final path in bundle.notebookPaths) {
      await _ensureNotebookPath(path, idByName, (nb) {
        idByName[nb.name] = nb.id;
        notebooksCreated++;
      });
    }
    // Also resolve per-note notebookPath fields.
    for (final n in bundle.notes) {
      if (n.notebookPath != null && n.notebookPath!.isNotEmpty) {
        await _ensureNotebookPath(n.notebookPath!, idByName, (nb) {
          idByName[nb.name] = nb.id;
          notebooksCreated++;
        });
      }
    }

    final now = DateTime.now().toUtc();
    // Map to store minted note ids for attachment wiring.
    final noteIdForIndex = <int, String>{};
    final notes = <Note>[
      for (var i = 0; i < bundle.notes.length; i++)
        _buildNote(bundle.notes[i], i, userId, idByName, now, noteIdForIndex),
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
    Map<String, String> idByName,
    DateTime now,
    Map<int, String> noteIdForIndex,
  ) {
    final id = _uuid.v4();
    noteIdForIndex[index] = id;

    String? notebookId;
    // notebookPath takes precedence over notebookName.
    if (n.notebookPath != null && n.notebookPath!.isNotEmpty) {
      notebookId = idByName[n.notebookPath!.last];
    } else if (n.notebookName != null && n.notebookName!.isNotEmpty) {
      notebookId = idByName[n.notebookName];
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
      updatedAt: n.updatedAt.isAfter(now) ? now : n.updatedAt,
      tagNames: n.tagNames,
    );
  }

  /// Walk a path of notebook names (e.g. ["Work", "Projects"]), creating
  /// any missing notebooks along the way. [onCreated] is called for each
  /// new notebook so callers can track counts and populate [idByName].
  Future<void> _ensureNotebookPath(
    List<String> path,
    Map<String, String> idByName,
    void Function(Notebook nb) onCreated,
  ) async {
    if (path.isEmpty) return;
    String? parentId;
    for (final name in path) {
      if (idByName.containsKey(name)) {
        parentId = idByName[name];
        continue;
      }
      // Need to check all existing notebooks to find a child with this name
      // under the current parent.
      final all = await _notebooks.listNotebooks();
      Notebook? match;
      for (final nb in all) {
        if (nb.name == name && nb.parentId == parentId) {
          match = nb;
          break;
        }
      }
      if (match != null) {
        idByName[name] = match.id;
        parentId = match.id;
        continue;
      }
      // Create it.
      final nb = await _notebooks.createNotebook(
        name: name,
        parentId: parentId,
      );
      idByName[name] = nb.id;
      parentId = nb.id;
      onCreated(nb);
    }
  }

  // --- Export ---

  /// Serialize the whole account (all live notes, notebooks, tags) to `.oblix`
  /// bytes. Trash (soft-deleted) is excluded; archived notes are included.
  Future<List<int>> exportOblix() async {
    final notes = await _notes.listNotes(archived: null, deleted: false);
    final notebooks = await _notebooks.listNotebooks();
    final tags = await _tags.listTags();

    // Gather attachments per note.
    final attachmentsByNoteId = <String, List<OblixAttachment>>{};
    for (final note in notes) {
      final atts = await _attachments.listForNote(note.id);
      final oblixAtts = <OblixAttachment>[];
      for (final a in atts) {
        final bytes = await _attachments.bytesFor(a);
        if (bytes == null) continue;
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
    return EpubExporter.notesToEpub(notes);
  }

  /// Export all notes as a ZIP of Markdown files.
  Future<List<int>> exportAllMarkdownZip() async {
    final notes = await _notes.listNotes(archived: null, deleted: false);
    return MarkdownExporter.notesToMarkdownZip(notes);
  }

  /// Export all notes as a ZIP of plain-text files.
  Future<List<int>> exportAllTextZip() async {
    final notes = await _notes.listNotes(archived: null, deleted: false);
    return TextExporter.notesToTextZip(notes);
  }

  /// Export a single note as a Markdown string.
  String exportNoteMarkdown(Note note) => MarkdownExporter.noteToMarkdown(note);

  /// Export a single note as a plain-text string.
  String exportNoteText(Note note) => TextExporter.noteToText(note);

  /// Export a single note as `.oblix` bytes (one-note archive).
  Future<List<int>> exportNoteOblix(Note note) async {
    final notebooks = await _notebooks.listNotebooks();
    final tags = await _tags.listTags();
    final attachmentsByNoteId = <String, List<OblixAttachment>>{};
    final atts = await _attachments.listForNote(note.id);
    final oblixAtts = <OblixAttachment>[];
    for (final a in atts) {
      final bytes = await _attachments.bytesFor(a);
      if (bytes == null) continue;
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
    return OblixArchive.encode(
      notes: [note],
      notebooks: notebooks,
      tags: tags,
      attachmentsByNoteId: attachmentsByNoteId,
    );
  }
}
