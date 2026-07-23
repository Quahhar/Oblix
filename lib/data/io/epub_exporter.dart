import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:uuid/uuid.dart';
import '../models/note.dart';

/// Hand-built EPUB 3 export (no dependency beyond `archive`). The layout:
///   * `mimetype`            — `application/epub+zip`, stored first, uncompressed
///   * `META-INF/container.xml`
///   * `OEBPS/content.opf`   — package metadata, manifest, spine
///   * `OEBPS/nav.xhtml`     — EPUB 3 navigation document
///   * `OEBPS/note-<i>.xhtml`— one chapter per note
///
/// Each chapter is the note title as an h1 plus the body as paragraphs
/// (split on blank lines, single newlines become br), all XML-escaped.
class EpubExporter {
  static const mediaType = 'application/epub+zip';

  /// All [notes] as one `.epub` book titled "Oblix export `date`".
  static List<int> notesToEpub(
    List<Note> notes, {
    DateTime? now,
    Uuid uuid = const Uuid(),
  }) {
    final exportedAt = (now ?? DateTime.now()).toUtc();
    final date = exportedAt.toIso8601String().split('T').first;
    // dcterms:modified wants whole seconds, no fractional part.
    final modified = '${exportedAt.toIso8601String().split('.').first}Z';
    final bookId = 'urn:uuid:${uuid.v4()}';
    final title = 'Oblix export $date';

    final archive = Archive();
    final mime = utf8.encode(mediaType);
    // EPUB mandates: first entry, stored (uncompressed) — epubcheck rejects
    // a deflated mimetype even though most readers tolerate it.
    archive.addFile(
      ArchiveFile('mimetype', mime.length, mime)
        ..compression = CompressionType.none,
    );
    archive.addFile(_xmlFile('META-INF/container.xml', _containerXml()));
    archive.addFile(
      _xmlFile('OEBPS/content.opf', _opf(title, bookId, modified, notes)),
    );
    archive.addFile(_xmlFile('OEBPS/nav.xhtml', _nav(title, notes)));
    for (var i = 0; i < notes.length; i++) {
      archive.addFile(_xmlFile('OEBPS/note-$i.xhtml', _chapter(notes[i])));
    }
    return ZipEncoder().encode(archive);
  }

  static String _containerXml() => '''<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
''';

  static String _opf(
    String title,
    String bookId,
    String modified,
    List<Note> notes,
  ) {
    final buf = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln(
        '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" '
        'unique-identifier="bookid" xml:lang="en">',
      )
      ..writeln('  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">')
      ..writeln('    <dc:identifier id="bookid">$bookId</dc:identifier>')
      ..writeln('    <dc:title>${_esc(title)}</dc:title>')
      ..writeln('    <dc:language>en</dc:language>')
      ..writeln('    <meta property="dcterms:modified">$modified</meta>')
      ..writeln('  </metadata>')
      ..writeln('  <manifest>')
      ..writeln(
        '    <item id="nav" href="nav.xhtml" '
        'media-type="application/xhtml+xml" properties="nav"/>',
      );
    for (var i = 0; i < notes.length; i++) {
      buf.writeln(
        '    <item id="note-$i" href="note-$i.xhtml" '
        'media-type="application/xhtml+xml"/>',
      );
    }
    buf.writeln('  </manifest>');
    buf.writeln('  <spine>');
    for (var i = 0; i < notes.length; i++) {
      buf.writeln('    <itemref idref="note-$i"/>');
    }
    buf
      ..writeln('  </spine>')
      ..writeln('</package>');
    return buf.toString();
  }

  static String _nav(String title, List<Note> notes) {
    final buf = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln(
        '<html xmlns="http://www.w3.org/1999/xhtml" '
        'xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="en" lang="en">',
      )
      ..writeln('<head><title>${_esc(title)}</title></head>')
      ..writeln('<body>')
      ..writeln('<nav epub:type="toc">')
      ..writeln('<h1>${_esc(title)}</h1>')
      ..writeln('<ol>');
    for (var i = 0; i < notes.length; i++) {
      buf.writeln(
        '<li><a href="note-$i.xhtml">${_esc(notes[i].title)}</a></li>',
      );
    }
    buf
      ..writeln('</ol>')
      ..writeln('</nav>')
      ..writeln('</body>')
      ..writeln('</html>');
    return buf.toString();
  }

  static String _chapter(Note note) {
    final buf = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln(
        '<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en" lang="en">',
      )
      ..writeln('<head><title>${_esc(note.title)}</title></head>')
      ..writeln('<body>')
      ..writeln('<h1>${_esc(note.title)}</h1>');
    for (final paragraph in note.content.split(RegExp(r'\n\s*\n'))) {
      if (paragraph.trim().isEmpty) continue;
      final body = _esc(paragraph.trim()).replaceAll('\n', '<br/>');
      buf.writeln('<p>$body</p>');
    }
    buf
      ..writeln('</body>')
      ..writeln('</html>');
    return buf.toString();
  }

  static String _esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  static ArchiveFile _xmlFile(String name, String xml) {
    final bytes = utf8.encode(xml);
    return ArchiveFile(name, bytes.length, bytes);
  }
}
