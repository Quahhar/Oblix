import 'package:xml/xml.dart';
import 'import_models.dart';

/// Parses Evernote's `.enex` export format into an [ImportBundle].
///
/// An ENEX file is `<en-export>` with `<note>` children. Each note's `<content>`
/// is ENML — an XHTML document wrapped in `<en-note>` — which we flatten to
/// plain text (the client has no rich model yet; text is lossless-enough and
/// never corrupts). Embedded `<resource>` media is counted but not imported
/// (no client attachment support yet).
class EnexParser {
  /// [notebookName] groups every note in the file under one notebook — ENEX
  /// carries no notebook name itself, so callers typically pass the file name.
  static ImportBundle parse(String xmlString, {String? notebookName}) {
    final doc = XmlDocument.parse(xmlString);
    final notes = <ImportedNote>[];

    for (final noteEl in doc.findAllElements('note')) {
      final title = noteEl.getElement('title')?.innerText.trim() ?? '';
      final enml = noteEl.getElement('content')?.innerText ?? '';
      final content = _enmlToText(enml);

      final created = _parseEnexTs(noteEl.getElement('created')?.innerText);
      final updated =
          _parseEnexTs(noteEl.getElement('updated')?.innerText) ?? created;

      final tags = noteEl
          .findElements('tag')
          .map((t) => t.innerText.trim())
          .where((t) => t.isNotEmpty)
          .toList();

      final attributes = noteEl.getElement('note-attributes');
      final pinned = attributes
              ?.getElement('reminder-order')
              ?.innerText
              .trim()
              .isNotEmpty ??
          false;

      final resources = noteEl.findElements('resource').length;

      notes.add(ImportedNote(
        title: title.isEmpty ? 'Untitled' : title,
        content: content,
        contentType: 'plain',
        tagNames: tags,
        isPinned: pinned,
        createdAt: created ?? DateTime.now().toUtc(),
        updatedAt: updated ?? DateTime.now().toUtc(),
        notebookName: notebookName,
        skippedAttachments: resources,
      ));
    }

    return ImportBundle(
      notes,
      notebookNames: notebookName != null && notes.isNotEmpty
          ? [notebookName]
          : const [],
    );
  }

  /// Flatten ENML/XHTML to plain text, turning block elements and `<br>` into
  /// line breaks. Falls back to a tag strip if the fragment won't parse.
  static String _enmlToText(String enml) {
    if (enml.trim().isEmpty) return '';
    try {
      final doc = XmlDocument.parse(enml);
      final root = doc.getElement('en-note') ?? doc.rootElement;
      final buf = StringBuffer();
      _walk(root, buf);
      return _tidy(buf.toString());
    } catch (_) {
      // Malformed ENML — strip tags as a last resort so import never fails.
      final stripped = enml
          .replaceAll(RegExp(r'<\s*br\s*/?>', caseSensitive: false), '\n')
          .replaceAll(RegExp(r'</\s*(div|p|li|h[1-6]|tr)\s*>',
              caseSensitive: false), '\n')
          .replaceAll(RegExp(r'<[^>]+>'), '');
      return _tidy(_unescape(stripped));
    }
  }

  static const _blockTags = {
    'div', 'p', 'br', 'li', 'tr', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
    'blockquote', 'ul', 'ol', 'table',
  };

  static void _walk(XmlNode node, StringBuffer buf) {
    for (final child in node.children) {
      if (child is XmlText || child is XmlCDATA) {
        buf.write(child.value);
      } else if (child is XmlElement) {
        final tag = child.name.local.toLowerCase();
        if (tag == 'br') {
          _ensureNewline(buf);
          continue;
        }
        final block = _blockTags.contains(tag);
        // Ensure a single break at each block boundary — never a doubled one
        // when blocks abut, which would read as spurious blank lines.
        if (block) _ensureNewline(buf);
        _walk(child, buf);
        if (block) _ensureNewline(buf);
      }
    }
  }

  static void _ensureNewline(StringBuffer buf) {
    final s = buf.toString();
    if (s.isNotEmpty && !s.endsWith('\n')) buf.write('\n');
  }

  /// Collapse runs of blank lines and trailing whitespace left by flattening.
  static String _tidy(String s) {
    final lines = s
        .replaceAll('\r\n', '\n')
        .split('\n')
        .map((l) => l.trimRight())
        .toList();
    final out = <String>[];
    var blanks = 0;
    for (final line in lines) {
      if (line.trim().isEmpty) {
        blanks++;
        if (blanks <= 1) out.add('');
      } else {
        blanks = 0;
        out.add(line);
      }
    }
    return out.join('\n').trim();
  }

  static String _unescape(String s) => s
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'");

  /// Evernote timestamps look like `20200131T134501Z` (basic ISO-8601).
  static DateTime? _parseEnexTs(String? raw) {
    if (raw == null) return null;
    final m = RegExp(r'^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z?$')
        .firstMatch(raw.trim());
    if (m == null) return null;
    return DateTime.utc(
      int.parse(m[1]!),
      int.parse(m[2]!),
      int.parse(m[3]!),
      int.parse(m[4]!),
      int.parse(m[5]!),
      int.parse(m[6]!),
    );
  }
}
