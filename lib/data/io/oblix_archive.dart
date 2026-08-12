import 'dart:convert';
import 'package:archive/archive.dart';
import '../../core/native/oblix_core.dart';
import '../models/note.dart';
import '../models/notebook.dart';
import '../models/tag.dart';
import 'import_models.dart';

/// One attachment handed to [OblixArchive.encode]: metadata plus the raw
/// bytes, which are stored as a blob inside the ZIP.
class OblixAttachment {
  final String id;
  final String originalName;
  final String mimeType;
  final List<int> bytes;

  const OblixAttachment({
    required this.id,
    required this.originalName,
    required this.mimeType,
    required this.bytes,
  });
}

/// Read/write the native `.oblix` export format.
///
/// The container is a ZIP holding:
///   * `manifest.json` — format id, version, export time, entity counts
///   * `data.json`     — the notes, notebooks and tags
///   * `files/`        — attachment blobs (v2), referenced from `data.json`
///
/// Notes reference their notebook by **name path**, not id, so an export
/// stays portable across accounts (import mints fresh ids and re-links by
/// name). v1 files (flat `notebook_name`, no `files/`) still decode.
class OblixArchive {
  static const formatId = 'oblix-export';
  static const formatVersion = 2;
  static const manifestName = 'manifest.json';
  static const dataName = 'data.json';

  /// Serialize a full snapshot to `.oblix` bytes. [attachmentsByNoteId] maps
  /// a note id to its attachments; each blob lands at
  /// `files/<noteId>/<attachmentId><ext>` and is referenced from the note's
  /// `attachments` list in `data.json`.
  static List<int> encode({
    required List<Note> notes,
    required List<Notebook> notebooks,
    required List<Tag> tags,
    Map<String, List<OblixAttachment>> attachmentsByNoteId = const {},
  }) {
    if (isRustCoreReady) {
      return encodeOblixArchiveCore(
        notes: [
          for (final note in notes)
            (
              id: note.id,
              notebookId: note.notebookId,
              title: note.title,
              content: note.content,
              contentType: note.contentType,
              tagNames: note.tagNames,
              isPinned: note.isPinned,
              isArchived: note.isArchived,
              createdAtIsoUtc: note.createdAt.toUtc().toIso8601String(),
              updatedAtIsoUtc: note.updatedAt.toUtc().toIso8601String(),
            ),
        ],
        notebooks: [
          for (final notebook in notebooks)
            (
              id: notebook.id,
              name: notebook.name,
              parentId: notebook.parentId,
              sortOrder: notebook.sortOrder,
            ),
        ],
        tagNames: [for (final tag in tags) tag.name],
        attachmentGroups: [
          for (final entry in attachmentsByNoteId.entries)
            (
              noteId: entry.key,
              attachments: [
                for (final attachment in entry.value)
                  (
                    id: attachment.id,
                    originalName: attachment.originalName,
                    mimeType: attachment.mimeType,
                    bytes: attachment.bytes,
                  ),
              ],
            ),
        ],
        exportedAtMicrosUtc: DateTime.now().toUtc().microsecondsSinceEpoch,
      );
    }
    final nbById = {for (final nb in notebooks) nb.id: nb};
    final pathById = {
      for (final nb in notebooks) nb.id: _notebookPath(nb, nbById),
    };

    final data = <String, dynamic>{
      'notes': [
        for (final n in notes)
          {
            'title': n.title,
            'content': n.content,
            'content_type': n.contentType,
            'tags': n.tagNames,
            'is_pinned': n.isPinned,
            'is_archived': n.isArchived,
            'notebook_path': n.notebookId == null
                ? null
                : pathById[n.notebookId],
            if ((attachmentsByNoteId[n.id] ?? const []).isNotEmpty)
              'attachments': [
                for (final a in attachmentsByNoteId[n.id]!)
                  {
                    'ref': _blobRef(n.id, a),
                    'original_name': a.originalName,
                    'mime_type': a.mimeType,
                  },
              ],
            'created_at': n.createdAt.toUtc().toIso8601String(),
            'updated_at': n.updatedAt.toUtc().toIso8601String(),
          },
      ],
      'notebooks': [
        for (final nb in notebooks)
          {
            'name': nb.name,
            'sort_order': nb.sortOrder,
            'path': pathById[nb.id],
          },
      ],
      'tags': [
        for (final t in tags) {'name': t.name},
      ],
    };

    final manifest = <String, dynamic>{
      'format': formatId,
      'version': formatVersion,
      'app': 'Oblix',
      'exported_at': DateTime.now().toUtc().toIso8601String(),
      'counts': {
        'notes': notes.length,
        'notebooks': notebooks.length,
        'tags': tags.length,
        'attachments': attachmentsByNoteId.values.fold(
          0,
          (sum, l) => sum + l.length,
        ),
      },
    };

    final archive = Archive()
      ..addFile(_jsonFile(manifestName, manifest))
      ..addFile(_jsonFile(dataName, data));
    for (final n in notes) {
      for (final a in attachmentsByNoteId[n.id] ?? const <OblixAttachment>[]) {
        archive.addFile(
          ArchiveFile(_blobRef(n.id, a), a.bytes.length, a.bytes),
        );
      }
    }
    return ZipEncoder().encode(archive);
  }

  /// Parse `.oblix` bytes into an [ImportBundle]. Throws [FormatException] if
  /// the file isn't a recognizable Oblix export. A declared attachment whose
  /// blob is missing from the ZIP is counted as skipped, not fatal.
  static ImportBundle decode(List<int> bytes) {
    if (isRustCoreReady) {
      return ImportBundle.fromCore(
        decodeOblixArchiveCore(
          bytes: bytes,
          nowMicrosUtc: DateTime.now().toUtc().microsecondsSinceEpoch,
        ),
      );
    }
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw const FormatException('Not a valid .oblix file (bad archive).');
    }

    final manifestRaw = _read(archive, manifestName);
    if (manifestRaw != null) {
      final manifest = jsonDecode(manifestRaw) as Map<String, dynamic>;
      if (manifest['format'] != formatId) {
        throw const FormatException('Not an Oblix export.');
      }
      if ((manifest['version'] as int? ?? 0) > formatVersion) {
        throw const FormatException(
          'This .oblix file was made by a newer version of Oblix.',
        );
      }
    }

    final dataRaw = _read(archive, dataName);
    if (dataRaw == null) {
      throw const FormatException('Corrupt .oblix file (no data).');
    }
    final data = jsonDecode(dataRaw) as Map<String, dynamic>;

    final notebookNames = <String>[];
    final notebookPaths = <List<String>>[];
    for (final nb in (data['notebooks'] as List? ?? const [])) {
      final entry = nb as Map<String, dynamic>;
      final path = _stringList(entry['path']);
      if (path != null && path.isNotEmpty) {
        notebookPaths.add(path);
      } else if (entry['name'] is String &&
          (entry['name'] as String).isNotEmpty) {
        notebookNames.add(entry['name'] as String);
      }
    }

    final notes = <ImportedNote>[];
    for (final raw in (data['notes'] as List? ?? const [])) {
      final n = raw as Map<String, dynamic>;
      final created =
          DateTime.tryParse(n['created_at'] as String? ?? '') ??
          DateTime.now().toUtc();

      final attachments = <ImportedAttachment>[];
      var missingBlobs = 0;
      for (final a in (n['attachments'] as List? ?? const [])) {
        final entry = a as Map<String, dynamic>;
        final ref = entry['ref'] as String?;
        final file = ref == null ? null : archive.findFile(ref);
        if (file == null) {
          // Blob declared but absent (trimmed/corrupt archive) — skip it,
          // don't fail the whole import.
          missingBlobs++;
          continue;
        }
        attachments.add(
          ImportedAttachment(
            originalName: entry['original_name'] as String? ?? 'file',
            mimeType: entry['mime_type'] as String?,
            bytes: file.content as List<int>,
          ),
        );
      }

      notes.add(
        ImportedNote(
          title: n['title'] as String? ?? 'Untitled',
          content: n['content'] as String? ?? '',
          contentType: n['content_type'] as String? ?? 'plain',
          tagNames: [
            for (final t in (n['tags'] as List? ?? const [])) t.toString(),
          ],
          isPinned: n['is_pinned'] as bool? ?? false,
          isArchived: n['is_archived'] as bool? ?? false,
          createdAt: created,
          updatedAt:
              DateTime.tryParse(n['updated_at'] as String? ?? '') ?? created,
          notebookName: n['notebook_name'] as String?,
          notebookPath: _stringList(n['notebook_path']),
          attachments: attachments,
          skippedAttachments: missingBlobs,
        ),
      );
    }

    return ImportBundle(
      notes,
      notebookNames: notebookNames,
      notebookPaths: notebookPaths,
    );
  }

  /// Names from the root down to [nb] (inclusive), walking `parentId`. A
  /// missing parent or a cycle just truncates the path — export never fails
  /// over a broken link.
  static List<String> _notebookPath(Notebook nb, Map<String, Notebook> byId) {
    final path = <String>[];
    final seen = <String>{};
    var current = nb;
    while (seen.add(current.id)) {
      path.insert(0, current.name);
      final parentId = current.parentId;
      if (parentId == null) break;
      final parent = byId[parentId];
      if (parent == null) break;
      current = parent;
    }
    return path;
  }

  static String _blobRef(String noteId, OblixAttachment a) =>
      'files/$noteId/${a.id}${_extension(a.originalName)}';

  static String _extension(String name) {
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return '';
    return name.substring(dot).toLowerCase();
  }

  static List<String>? _stringList(Object? raw) {
    if (raw is! List) return null;
    final out = [
      for (final s in raw)
        if (s.toString().isNotEmpty) s.toString(),
    ];
    return out.isEmpty ? null : out;
  }

  static ArchiveFile _jsonFile(String name, Object json) {
    final bytes = utf8.encode(const JsonEncoder.withIndent('  ').convert(json));
    return ArchiveFile(name, bytes.length, bytes);
  }

  static String? _read(Archive archive, String name) {
    final file = archive.findFile(name);
    if (file == null) return null;
    return utf8.decode(file.content as List<int>);
  }
}
