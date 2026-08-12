import 'dart:ui' show Size;

import '../../../core/native/crdt_types.dart';

export 'document_scanner_stub.dart'
    if (dart.library.io) 'document_scanner_mlkit.dart';

/// Where the page comes from.
///
/// [document] is the guided flow: the platform finds the page edges, corrects
/// the perspective, and can take several pages in one go — which is worth a
/// lot, because a straightened crop recognizes far better than a snapshot of a
/// page lying at an angle. It needs Play Services, so it falls back to
/// [camera] where it is unavailable.
enum ScanSource { document, camera, gallery }

/// Raw recognizer output for a capture, before the Rust core turns it into
/// prose. [pageImagePaths] are the captured files in order, kept so the review
/// screen can show what was read and so they can be attached to the note.
class ScanCapture {
  const ScanCapture({
    required this.pages,
    required this.pageImagePaths,
    required this.pageSizes,
    required this.guided,
    this.script = ScriptValue.latin,
  });

  /// The writing system the pages were finally read with. Worth keeping: it is
  /// what the core concluded after scoring the models against each other, and
  /// a page read as Japanese is a different claim from one read as Latin.
  final ScriptValue script;

  /// Recognized lines per page, in page order.
  final List<List<OcrLineValue>> pages;

  final List<String> pageImagePaths;

  /// Pixel size of each captured image, parallel to [pages]. The core uses it
  /// to classify the page — a receipt is recognizable partly by being long and
  /// narrow, which the text boxes alone cannot show. `Size.zero` where the
  /// dimensions could not be read; the core treats that as "unknown" rather
  /// than as a square page.
  final List<Size> pageSizes;

  /// Whether the guided document flow produced these, rather than a raw photo.
  final bool guided;

  /// The first page's image, for the review preview.
  String get imagePath => pageImagePaths.first;

  int get pageCount => pages.length;

  /// The capture as reconstruction input.
  List<OcrPageValue> get corePages => [
    for (var index = 0; index < pages.length; index++)
      (
        lines: pages[index],
        width: index < pageSizes.length ? pageSizes[index].width : 0.0,
        height: index < pageSizes.length ? pageSizes[index].height : 0.0,
      ),
  ];
}

/// Thrown when the platform cannot scan — desktop and web have no on-device
/// recognizer wired up, and the plugin is Android/iOS only.
class ScanUnsupportedException implements Exception {
  const ScanUnsupportedException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Thrown when capture or recognition fails for a reason worth showing.
class ScanFailedException implements Exception {
  const ScanFailedException(this.message);
  final String message;

  @override
  String toString() => message;
}
