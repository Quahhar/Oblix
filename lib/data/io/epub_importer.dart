import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import '../../core/native/oblix_core.dart';
import 'import_models.dart';

/// Parses an EPUB file into an [ImportBundle] — one note per spine chapter.
///
/// Steps:
///   1. Open ZIP, read `META-INF/container.xml` for the OPF path.
///   2. Parse the OPF to get the `<spine>` order and `dc:title`.
///   3. For each spine XHTML, strip tags to plain text (block tags → newlines)
///      and extract the chapter title from `<h1>` / `<title>` / fallback.
class EpubImporter {
  /// Parse raw EPUB bytes. Throws [FormatException] on an unrecognised file.
  static ImportBundle parse(List<int> bytes) {
    if (isRustCoreReady) {
      return ImportBundle.fromCore(
        importEpubCore(
          bytes: bytes,
          nowMicrosUtc: DateTime.now().toUtc().microsecondsSinceEpoch,
        ),
      );
    }
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw const FormatException('Not a valid EPUB file (bad archive).');
    }

    final containerXml = _read(archive, 'META-INF/container.xml');
    if (containerXml == null) {
      throw const FormatException('Not a valid EPUB (missing container.xml).');
    }
    final opfPath = _opfPath(containerXml);
    if (opfPath == null) {
      throw const FormatException('EPUB container.xml has no rootfile.');
    }

    final opfXml = _read(archive, opfPath);
    if (opfXml == null) {
      throw FormatException('EPUB missing OPF at $opfPath.');
    }
    final opf = XmlDocument.parse(opfXml);
    final title = _dcTitle(opf) ?? 'Imported EPUB';
    final spineHrefs = _spineHrefs(opf);

    // Resolve each spine item relative to OPF directory.
    final baseDir = _dirname(opfPath);
    final notes = <ImportedNote>[];
    for (var i = 0; i < spineHrefs.length; i++) {
      final href = spineHrefs[i];
      final fullPath = baseDir.isEmpty ? href : '$baseDir/$href';
      final xhtml = _read(archive, fullPath);
      if (xhtml == null) continue; // missing file in archive — skip
      final (chapterTitle, content) = _parseXhtml(xhtml, i);
      notes.add(
        ImportedNote(
          title: chapterTitle,
          content: content,
          contentType: 'plain',
          createdAt: DateTime.now().toUtc(),
          updatedAt: DateTime.now().toUtc(),
          notebookName: title,
        ),
      );
    }

    if (notes.isEmpty) {
      throw const FormatException('EPUB has no readable chapters.');
    }

    return ImportBundle(notes, notebookNames: [title]);
  }

  static String? _read(Archive archive, String path) {
    final file = archive.findFile(path);
    if (file == null) return null;
    return utf8.decode(file.content as List<int>);
  }

  static String? _opfPath(String containerXml) {
    final doc = XmlDocument.parse(containerXml);
    // rootfile sits at container > rootfiles > rootfile, so a shallow
    // getElement (direct children only) can't reach it — search the tree.
    final rootfile = doc.findAllElements('rootfile').firstOrNull;
    return rootfile?.getAttribute('full-path');
  }

  static String? _dcTitle(XmlDocument opf) {
    for (final el in opf.findAllElements('title')) {
      // The dc:title inside <metadata>
      final parent = el.parentElement;
      if (parent != null && parent.name.local == 'metadata') {
        return el.innerText.trim();
      }
    }
    // Also try dc:title with namespace prefix.
    for (final el in opf.findAllElements('dc:title')) {
      return el.innerText.trim();
    }
    return null;
  }

  static List<String> _spineHrefs(XmlDocument opf) {
    final manifest = <String, String>{};
    for (final item in opf.findAllElements('item')) {
      final id = item.getAttribute('id');
      final href = item.getAttribute('href');
      if (id != null && href != null) manifest[id] = href;
    }
    final hrefs = <String>[];
    for (final itemref in opf.findAllElements('itemref')) {
      final idref = itemref.getAttribute('idref');
      if (idref != null && manifest.containsKey(idref)) {
        hrefs.add(manifest[idref]!);
      }
    }
    return hrefs;
  }

  static String _dirname(String path) {
    final slash = path.lastIndexOf('/');
    return slash >= 0 ? path.substring(0, slash) : '';
  }

  /// Strip XHTML tags: block tags become newlines, everything else is
  /// just dropped (text content kept). Extract the first `<h1>` or
  /// `<title>` as the chapter title.
  static (String, String) _parseXhtml(String xhtml, int index) {
    final doc = XmlDocument.parse(_sanitizeXhtmlContent(xhtml));
    final root = doc.rootElement;

    // Extract title from the first h1 or <title>.
    String? title;
    final h1 = root.findAllElements('h1').firstOrNull;
    if (h1 != null) title = h1.innerText.trim();
    if (title == null || title.isEmpty) {
      final t = root.findAllElements('title').firstOrNull;
      if (t != null) title = t.innerText.trim();
    }
    if (title == null || title.isEmpty) {
      title = 'Chapter ${index + 1}';
    }

    final buf = StringBuffer();
    _walkXhtml(root, buf);
    return (title, _tidy(buf.toString()));
  }

  /// The raw XHTML content *inside* the .xhtml file is just a string; but
  /// that string may contain a DOCTYPE or other bits in front of the root.
  /// We parse only the content inside the `<html>` block. If the parse
  /// fails, we return an empty fragment.
  static String _sanitizeXhtmlContent(String raw) {
    // Try extracting just the html tag block if the whole doc won't parse.
    try {
      XmlDocument.parse(raw);
      return raw;
    } catch (_) {
      final m = RegExp(
        r'<html[^>]*>.*</html>',
        caseSensitive: false,
        dotAll: true,
      ).firstMatch(raw);
      return m?.group(0) ?? raw;
    }
  }

  static const _blockTags = {
    'div',
    'p',
    'br',
    'li',
    'tr',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'blockquote',
    'ul',
    'ol',
    'table',
    'section',
    'article',
    'header',
    'footer',
    'nav',
    'pre',
    'hr',
  };

  static void _walkXhtml(XmlNode node, StringBuffer buf) {
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
        if (block) _ensureNewline(buf);
        _walkXhtml(child, buf);
        if (block) _ensureNewline(buf);
      }
    }
  }

  static void _ensureNewline(StringBuffer buf) {
    final s = buf.toString();
    if (s.isNotEmpty && !s.endsWith('\n')) buf.write('\n');
  }

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
}
