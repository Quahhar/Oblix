import 'dart:convert';
import 'import_models.dart';

/// Parses `.md` and `.txt` bytes into an [ImportBundle].
///
/// For Markdown, the first `#`-heading becomes the title; everything else is
/// the body (markdown source as-is). For `.txt`, the filename stem is the
/// title and the whole content is the body.
class MarkdownImporter {
  /// Parse one file's bytes. [filename] provides a fallback title.
  static ImportedNote parseOne(List<int> bytes, String filename) {
    final isMarkdown = _isMd(filename);
    final text = utf8.decode(bytes);
    final (title, content) = _splitTitle(text);
    return ImportedNote(
      title: title ?? _stemFromFilename(filename),
      content: content,
      contentType: isMarkdown ? 'markdown' : 'plain',
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

  /// Return the first `#` heading as the title (stripped of leading `#` and
  /// whitespace) and the rest as content. If no heading is found, the title
  /// is null and the full text is content.
  static (String?, String) _splitTitle(String text) {
    final lines = text
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n');
    final clean = <String>[];
    String? title;
    var headingFound = false;
    for (final line in lines) {
      if (!headingFound) {
        final trimmed = line.trimLeft();
        if (trimmed.startsWith('#') &&
            !trimmed.startsWith('##') &&
            line.trim().isNotEmpty) {
          title = trimmed.substring(1).trim();
          title = title.isEmpty ? null : title;
          headingFound = true;
          continue;
        }
      }
      clean.add(line);
    }
    var content = clean.join('\n');
    // Drop leading blank lines after the heading.
    content = content.replaceFirst(RegExp(r'^\n+'), '');
    return (title, content);
  }

  static bool _isMd(String filename) => filename.toLowerCase().endsWith('.md');

  static String _stemFromFilename(String filename) {
    final slash = filename.lastIndexOf(RegExp(r'[/\\]'));
    final base = slash >= 0 ? filename.substring(slash + 1) : filename;
    final dot = base.lastIndexOf('.');
    if (dot > 0) return base.substring(0, dot);
    return base;
  }
}
