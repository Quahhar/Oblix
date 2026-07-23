import 'dart:convert';

import 'package:archive/archive.dart';

import '../models/note.dart';

/// Exports notes as Markdown — single-file or bulk ZIP.
class MarkdownExporter {
  /// Render one note to a Markdown string: `#` heading, blank line, body,
  /// then a trailing `Tags: …` line when the note has tags.
  static String noteToMarkdown(Note note) {
    final buf = StringBuffer();
    final title = note.title == 'Untitled' ? '' : note.title;
    buf.writeln('# ${title.isNotEmpty ? title : 'Untitled'}');
    buf.writeln();
    buf.write(note.content);
    if (note.tagNames.isNotEmpty) {
      buf.writeln();
      buf.writeln();
      buf.write('Tags: ${note.tagNames.join(', ')}');
    }
    return buf.toString();
  }

  /// Produce a ZIP of `.md` files whose names are derived from note titles
  /// (sanitised to avoid collisions and invalid chars, with a short-id
  /// suffix for uniqueness).
  static List<int> notesToMarkdownZip(List<Note> notes) {
    final archive = Archive();
    final seen = <String, int>{};
    for (final n in notes) {
      final stem = _sanitisedStem(n.title, n.id);
      var filename = '$stem.md';
      if (seen.containsKey(filename)) {
        final idx = seen[filename]! + 1;
        seen[filename] = idx;
        filename = '$stem-$idx.md';
      } else {
        seen[filename] = 1;
      }
      final bytes = utf8.encode(noteToMarkdown(n));
      archive.addFile(ArchiveFile(filename, bytes.length, bytes));
    }
    return ZipEncoder().encode(archive);
  }

  /// Turn a note title into a safe filename stem (a-z, 0-9, -, _),
  /// truncated to ≤60 chars, plus the last 6 chars of the id as a
  /// disambiguation suffix.
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
