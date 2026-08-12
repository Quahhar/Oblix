import 'dart:convert';

import 'package:archive/archive.dart';

import '../models/note.dart';
import '../../core/native/oblix_core.dart';

/// Exports notes as Markdown — single-file or bulk ZIP.
class MarkdownExporter {
  /// Render one note to a Markdown string: `#` heading, blank line, body,
  /// then a trailing `Tags: …` line when the note has tags.
  static String noteToMarkdown(Note note) {
    return renderNoteMarkdown(_coreNote(note));
  }

  /// Produce a ZIP of `.md` files whose names are derived from note titles
  /// (sanitised to avoid collisions and invalid chars, with a short-id
  /// suffix for uniqueness).
  static List<int> notesToMarkdownZip(List<Note> notes) {
    final archive = Archive();
    final files = renderMarkdownFiles(notes.map(_coreNote).toList());
    for (final file in files) {
      final bytes = utf8.encode(file.content);
      archive.addFile(ArchiveFile(file.filename, bytes.length, bytes));
    }
    return ZipEncoder().encode(archive);
  }

  /// Turn a note title into a safe filename stem (a-z, 0-9, -, _),
  /// truncated to ≤60 chars, plus the last 6 chars of the id as a
  /// disambiguation suffix.
  static ExportNoteValue _coreNote(Note note) => (
    id: note.id,
    title: note.title,
    content: note.content,
    tagNames: note.tagNames,
  );
}
