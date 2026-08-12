import 'dart:convert';
import '../../core/native/oblix_core.dart';
import 'import_models.dart';

/// Parses `.md` and `.txt` bytes into an [ImportBundle].
///
/// For Markdown, the first `#`-heading becomes the title; everything else is
/// the body (markdown source as-is). For `.txt`, the filename stem is the
/// title and the whole content is the body.
class MarkdownImporter {
  /// Parse one file's bytes. [filename] provides a fallback title.
  static ImportedNote parseOne(List<int> bytes, String filename) {
    final text = utf8.decode(bytes);
    final parsed = parseMarkdownTextCore(text, filename);
    return ImportedNote(
      title: parsed.title,
      content: parsed.content,
      contentType: parsed.contentType,
      createdAt: DateTime.now().toUtc(),
      updatedAt: DateTime.now().toUtc(),
    );
  }

  /// Parse multiple files into one [ImportBundle]. Each file becomes one note.
  static ImportBundle parseMany(List<(String name, List<int> bytes)> files) {
    final notes = <ImportedNote>[];
    for (final (name, bytes) in files) {
      notes.add(parseOne(bytes, name));
    }
    return ImportBundle(notes);
  }
}
