import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../../core/native/oblix_core.dart';
import 'document_scanner.dart';
import 'pdf_reader.dart';

/// PDFium is bundled natively, so this is everywhere except the web.
const bool pdfReadingSupported = true;

/// Pages read in one go unless the caller says otherwise. A long document is
/// worth truncating: nobody wants a thousand-page manual as one note, and
/// recognizing that many rendered pages would take minutes.
const int defaultMaxPdfPages = 50;

/// Pixels per point when a page has to be rendered for recognition.
///
/// A PDF point is 1/72 inch, so 2.0 is 144 dpi. Below about 150 dpi small
/// print stops recognizing reliably; far above it the bitmaps get large
/// without reading any better.
const double _ocrRenderScale = 2.0;

bool _initialized = false;

void _ensureInitialized() {
  if (_initialized) return;
  pdfrxFlutterInitialize();
  _initialized = true;
}

/// Read a PDF into the same page input a camera produces.
///
/// Each page is decided on its own by the Rust core: a page carrying real text
/// is used as it stands, because recognizing type that is already perfect can
/// only introduce mistakes; a page that is a photograph in a wrapper is
/// rendered and put through the recognizer. Mixed documents — a report with a
/// scanned appendix — therefore come out right without the user choosing.
Future<PdfReading> readPdf(String path, {int maxPages = defaultMaxPdfPages}) async {
  _ensureInitialized();
  final limit = maxPages > 0 ? maxPages : defaultMaxPdfPages;

  final PdfDocument document;
  try {
    document = await PdfDocument.openFile(path);
  } catch (error) {
    throw PdfReadException('Could not open that PDF: $error');
  }

  final pages = <OcrPageValue>[];
  var recognized = 0;
  var skipped = 0;
  try {
    final count = document.pages.length < limit ? document.pages.length : limit;
    for (var index = 0; index < count; index++) {
      final page = document.pages[index];
      final runs = await _runsOf(page);
      final assessment = assessPdfPage((
        runs: runs,
        width: page.width,
        height: page.height,
        hasImage: runs.isEmpty,
      ));

      if (assessment.plan == PdfPagePlanValue.useText) {
        pages.add(
          pdfPagesToOcrPages(
            pages: [
              (
                runs: runs,
                width: page.width,
                height: page.height,
                hasImage: false,
              ),
            ],
          ).single,
        );
        continue;
      }

      final read = await _renderAndRecognize(page);
      if (read == null) {
        skipped++;
        continue;
      }
      pages.add(read);
      recognized++;
    }
  } finally {
    await document.dispose();
  }

  return PdfReading(
    pages: pages,
    recognizedPages: recognized,
    skippedPages: skipped,
  );
}

/// The page's embedded text, as positioned runs.
///
/// `PdfRect` is in PDF user space with `top` above `bottom`, which is exactly
/// what the core's [PdfTextRunValue] expects — `y` is the bottom edge and the
/// height is measured upward from it. No flipping happens here; the core does
/// that once, for every source.
Future<List<PdfTextRunValue>> _runsOf(PdfPage page) async {
  final PdfPageText text;
  try {
    text = await page.loadStructuredText();
  } catch (_) {
    return const [];
  }
  final runs = <PdfTextRunValue>[];
  for (final fragment in text.fragments) {
    final content = fragment.text;
    if (content.trim().isEmpty) continue;
    final bounds = fragment.bounds;
    runs.add((
      text: content,
      x: bounds.left,
      y: bounds.bottom,
      width: bounds.right - bounds.left,
      height: bounds.top - bounds.bottom,
    ));
  }
  return runs;
}

/// Render a page and run the recognizer over it.
///
/// The rendered bitmap is written to a temporary file because that is what the
/// recognizer takes; it is deleted immediately afterwards, since the PDF is
/// the durable copy and a second one would only be a page of the user's
/// documents left lying in a cache directory.
Future<OcrPageValue?> _renderAndRecognize(PdfPage page) async {
  if (!scanningSupported) return null;
  File? temporary;
  try {
    final image = await page.render(
      fullWidth: page.width * _ocrRenderScale,
      fullHeight: page.height * _ocrRenderScale,
      backgroundColor: 0xFFFFFFFF,
    );
    if (image == null) return null;

    final encoded = await _encodePng(image);
    if (encoded == null) return null;

    final directory = await getTemporaryDirectory();
    temporary = File(
      p.join(directory.path, 'oblix-pdf-page-${page.pageNumber}.png'),
    );
    await temporary.writeAsBytes(encoded, flush: true);
    return await recognizeImageFile(temporary.path);
  } catch (_) {
    return null;
  } finally {
    try {
      await temporary?.delete();
    } catch (_) {
      // A leftover temp file is not worth failing the import over.
    }
  }
}

/// PDFium hands back raw BGRA; the recognizer wants an encoded image.
Future<List<int>?> _encodePng(PdfImage image) async {
  ui.Image? decoded;
  try {
    decoded = await _imageFromBgra(image);
    final data = await decoded.toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List();
  } catch (_) {
    return null;
  } finally {
    decoded?.dispose();
  }
}

Future<ui.Image> _imageFromBgra(PdfImage image) {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    image.pixels,
    image.width,
    image.height,
    ui.PixelFormat.bgra8888,
    completer.complete,
  );
  return completer.future;
}
