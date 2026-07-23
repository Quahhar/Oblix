import 'dart:convert';

import 'package:archive/archive.dart';

import '../models/note.dart';

/// Serialize notes to plain text — `title`, blank line, body — the same
/// shape the editor's Share action produces. Bulk export is a ZIP of one
/// `.txt` per note.
class TextExporter {
  /// One note as a plain-text document.
  static String noteToText(Note note) {
    final title = note.title.trim();
    final body = note.content.trimRight();
    if (title.isEmpty || title == 'Untitled') return body;
    return '$title\n\n$body';
  }

  /// Many notes as a ZIP holding one `.txt` file per note.
  static List<int> notesToTextZip(List<Note> notes) {
    final archive = Archive();
    final seen = <String, int>{};
    for (final n in notes) {
      final stem = _sanitisedStem(n.title, n.id);
      var filename = '$stem.txt';
      if (seen.containsKey(filename)) {
        final idx = seen[filename]! + 1;
        seen[filename] = idx;
        filename = '$stem-$idx.txt';
      } else {
        seen[filename] = 1;
      }
      final bytes = utf8.encode(noteToText(n));
      archive.addFile(ArchiveFile(filename, bytes.length, bytes));
    }
    return ZipEncoder().encode(archive);
  }

  static String _sanitisedStem(String title, String id) {
    var stem = title
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\-\_\s]'), '')
        .replaceAll(RegExp(r'\s+'), '-')
        .trim();
    if (stem.isEmpty) stem = 'untitled';
    if (stem.length > 60) {
      stem = stem.substring(0, 60).replaceAll(RegExp(r'-+$'), '');
    }
    final suffix = id.length >= 6 ? id.substring(id.length - 6) : id;
    return '$stem-$suffix';
  }
}
