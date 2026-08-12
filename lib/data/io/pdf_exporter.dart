import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import '../models/note.dart';

/// The bundled serif faces, loaded and ready for `package:pdf`.
class PdfFonts {
  final pw.Font regular;
  final pw.Font bold;
  final pw.Font italic;

  const PdfFonts({
    required this.regular,
    required this.bold,
    required this.italic,
  });
}

/// Supplies the fonts a PDF is rendered with; returns null to fall back to
/// the built-in Helvetica. Injectable because asset loading needs a Flutter
/// binding, which unit tests don't have.
typedef PdfFontLoader = Future<PdfFonts?> Function();

/// Render notes to PDF with `package:pdf`. Each note starts on a new page;
/// long notes flow onto follow-up pages. Uses the bundled SourceSerif4 faces
/// when they're available and Helvetica otherwise.
class PdfExporter {
  /// Loads SourceSerif4 from the asset bundle. Only usable inside a Flutter
  /// binding — any failure (missing asset, no binding) means "fall back to
  /// the built-in fonts", never a failed export.
  static Future<PdfFonts?> bundledFonts() async {
    try {
      return PdfFonts(
        regular: pw.Font.ttf(
          await rootBundle.load('assets/fonts/SourceSerif4-Regular.ttf'),
        ),
        bold: pw.Font.ttf(
          await rootBundle.load('assets/fonts/SourceSerif4-Bold.ttf'),
        ),
        italic: pw.Font.ttf(
          await rootBundle.load('assets/fonts/SourceSerif4-Italic.ttf'),
        ),
      );
    } catch (_) {
      return null;
    }
  }

  /// One note as a PDF document.
  static Future<List<int>> noteToPdf(Note note, {PdfFontLoader? loadFonts}) =>
      notesToPdf([note], loadFonts: loadFonts);

  /// Many notes as a single PDF document, each note starting on a new page.
  static Future<List<int>> notesToPdf(
    List<Note> notes, {
    PdfFontLoader? loadFonts,
  }) async {
    final fonts = await (loadFonts ?? bundledFonts)();
    final doc = pw.Document();
    for (final note in notes) {
      doc.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(56),
          build: (_) => _noteContent(note, fonts),
        ),
      );
    }
    return doc.save();
  }

  static List<pw.Widget> _noteContent(Note note, PdfFonts? fonts) {
    final titleStyle = pw.TextStyle(
      font: fonts?.bold,
      fontSize: 22,
      fontWeight: pw.FontWeight.bold,
    );
    final metaStyle = pw.TextStyle(
      font: fonts?.italic,
      fontSize: 9.5,
      color: PdfColors.grey600,
    );
    final bodyStyle = pw.TextStyle(
      font: fonts?.regular,
      fontSize: 11.5,
      lineSpacing: 4,
    );

    final title = note.title.trim();
    final meta = [
      'Created ${_date(note.createdAt)}',
      'Updated ${_date(note.updatedAt)}',
      if (note.tagNames.isNotEmpty) 'Tags: ${note.tagNames.join(', ')}',
    ].join(' · ');

    return [
      if (title.isNotEmpty && title != 'Untitled') ...[
        pw.Text(title, style: titleStyle),
        pw.SizedBox(height: 6),
      ],
      pw.Text(meta, style: metaStyle),
      pw.SizedBox(height: 4),
      pw.Divider(color: PdfColors.grey400),
      pw.SizedBox(height: 12),
      // Blank-line-separated paragraphs, each wrapped independently.
      for (final paragraph in _paragraphs(note.content))
        pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 10),
          child: pw.Text(paragraph, style: bodyStyle),
        ),
    ];
  }

  static List<String> _paragraphs(String content) => [
    for (final p in content.split(RegExp(r'\n\s*\n')))
      if (p.trim().isNotEmpty) p.trim(),
  ];

  static String _date(DateTime t) => t.toIso8601String().split('T').first;
}
