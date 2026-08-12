import 'dart:convert';

import 'package:archive/archive.dart';

import '../models/note.dart';
import '../../core/native/oblix_core.dart';

/// Serialize notes to plain text — `title`, blank line, body — the same
/// shape the editor's Share action produces. Bulk export is a ZIP of one
/// `.txt` per note.
class TextExporter {
  /// One note as a plain-text document.
  static String noteToText(Note note) {
    return renderNoteText(_coreNote(note));
  }

  /// Many notes as a ZIP holding one `.txt` file per note.
  static List<int> notesToTextZip(List<Note> notes) {
    final archive = Archive();
    final files = renderTextFiles(notes.map(_coreNote).toList());
    for (final file in files) {
      final bytes = utf8.encode(file.content);
      archive.addFile(ArchiveFile(file.filename, bytes.length, bytes));
    }
    return ZipEncoder().encode(archive);
  }

  static ExportNoteValue _coreNote(Note note) => (
    id: note.id,
    title: note.title,
    content: note.content,
    tagNames: note.tagNames,
  );
}
