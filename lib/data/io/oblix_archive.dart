import 'dart:convert';
import 'package:archive/archive.dart';
import '../models/note.dart';
import '../models/notebook.dart';
import '../models/tag.dart';
import 'import_models.dart';

/// Read/write the native `.oblix` export format.
///
/// The container is a ZIP holding:
///   * `manifest.json` — format id, version, export time, entity counts
///   * `data.json`     — the notes, notebooks and tags
///
/// Notes reference their notebook by **name**, not id, so an export stays
/// portable across accounts (import mints fresh ids and re-links by name).
/// A ZIP was chosen over bare JSON so a future version can add an
/// `attachments/` folder without changing the format.
class OblixArchive {
  static const formatId = 'oblix-export';
  static const formatVersion = 1;
  static const manifestName = 'manifest.json';
  static const dataName = 'data.json';

  /// Serialize a full snapshot to `.oblix` bytes.
  static List<int> encode({
    required List<Note> notes,
    required List<Notebook> notebooks,
    required List<Tag> tags,
  }) {
    final nbNameById = {for (final nb in notebooks) nb.id: nb.name};

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
            'notebook_name': n.notebookId == null
                ? null
                : nbNameById[n.notebookId],
            'created_at': n.createdAt.toUtc().toIso8601String(),
            'updated_at': n.updatedAt.toUtc().toIso8601String(),
          },
      ],
      'notebooks': [
        for (final nb in notebooks)
          {'name': nb.name, 'sort_order': nb.sortOrder},
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
      },
    };

    final archive = Archive()
      ..addFile(_jsonFile(manifestName, manifest))
      ..addFile(_jsonFile(dataName, data));
    return ZipEncoder().encode(archive);
  }

  /// Parse `.oblix` bytes into an [ImportBundle]. Throws [FormatException] if
  /// the file isn't a recognizable Oblix export.
  static ImportBundle decode(List<int> bytes) {
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

    final notebookNames = <String>[
      for (final nb in (data['notebooks'] as List? ?? const []))
        if ((nb as Map)['name'] is String && (nb['name'] as String).isNotEmpty)
          nb['name'] as String,
    ];

    final notes = <ImportedNote>[];
    for (final raw in (data['notes'] as List? ?? const [])) {
      final n = raw as Map<String, dynamic>;
      final created = DateTime.tryParse(n['created_at'] as String? ?? '') ??
          DateTime.now().toUtc();
      notes.add(ImportedNote(
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
      ));
    }

    return ImportBundle(notes, notebookNames: notebookNames);
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
