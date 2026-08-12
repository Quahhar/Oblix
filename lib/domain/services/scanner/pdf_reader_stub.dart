import 'pdf_reader.dart';

/// Web build. PDFium is a native library, so reading a PDF reports itself
/// unavailable rather than pretending to work.
const bool pdfReadingSupported = false;

Future<PdfReading> readPdf(String path, {int maxPages = 0}) async {
  throw const PdfReadException('Reading PDFs needs Android, iOS or desktop.');
}
