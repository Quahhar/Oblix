import '../../../core/native/crdt_types.dart';

export 'pdf_reader_stub.dart'
    if (dart.library.io) 'pdf_reader_pdfrx.dart';

/// A PDF read into reconstruction input, page by page.
///
/// [pages] is the whole document in order, whatever each page needed: a
/// born-digital page contributes its own embedded text, a scanned one is
/// rendered and recognized. [recognizedPages] says how many took the second
/// route, which is the slow one and the only one that can make mistakes.
class PdfReading {
  const PdfReading({
    required this.pages,
    required this.recognizedPages,
    required this.skippedPages,
  });

  final List<OcrPageValue> pages;

  /// Pages that had no usable text and had to be recognized from pixels.
  final int recognizedPages;

  /// Pages that could be neither read nor recognized.
  final int skippedPages;

  int get pageCount => pages.length;

  bool get isEmpty => pages.every((page) => page.lines.isEmpty);
}

/// Thrown when the file is not a PDF this device can open — encrypted,
/// corrupt, or a format PDFium will not take.
class PdfReadException implements Exception {
  const PdfReadException(this.message);
  final String message;

  @override
  String toString() => message;
}
