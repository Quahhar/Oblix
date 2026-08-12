import 'dart:io';
import 'dart:ui' as ui show ImageDescriptor, ImmutableBuffer;
import 'dart:ui' show Size;

import 'package:google_mlkit_document_scanner/google_mlkit_document_scanner.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/native/oblix_core.dart';
import 'document_scanner.dart';
import 'page_preparer.dart';

/// ML Kit ships Android and iOS only. `dart.library.io` is also true on
/// desktop, so the platform is checked at runtime rather than at import time.
bool get scanningSupported => Platform.isAndroid || Platform.isIOS;

/// The guided flow is backed by Play Services, so it is Android in practice.
/// Everywhere else falls back to a plain camera shot.
bool get guidedScanSupported => Platform.isAndroid;

/// Most pages a single guided session will take.
const int maxScanPages = 10;

final ImagePicker _picker = ImagePicker();

/// Created lazily and reused per script: constructing a recognizer loads a
/// model, which is far too slow to do per scan.
final Map<TextRecognitionScript, TextRecognizer> _recognizers = {};

TextRecognizer _sharedRecognizer([
  TextRecognitionScript script = TextRecognitionScript.latin,
]) => _recognizers[script] ??= TextRecognizer(script: script);

/// The scripts an on-device model exists for, in the order they are tried.
///
/// Latin is first because it is the overwhelmingly common case and, on a page
/// that really is Latin, the rest never run.
const List<(TextRecognitionScript, ScriptValue)> _scripts = [
  (TextRecognitionScript.latin, ScriptValue.latin),
  (TextRecognitionScript.chinese, ScriptValue.chinese),
  (TextRecognitionScript.japanese, ScriptValue.japanese),
  (TextRecognitionScript.korean, ScriptValue.korean),
  (TextRecognitionScript.devanagiri, ScriptValue.devanagari),
];

/// Capture one or more pages and hand back the recognizer's raw line boxes.
///
/// Deliberately does no text assembly — that is the Rust core's job. This
/// function only bridges the platform: get images, run recognition, and
/// flatten each block/line tree into positioned lines.
///
/// Returns null when the user backs out.
Future<ScanCapture?> captureAndRecognize(ScanSource source) async {
  if (!scanningSupported) {
    throw const ScanUnsupportedException(
      'Scanning needs the camera on Android or iOS.',
    );
  }

  final (paths, guided) = await _capturePages(source);
  if (paths.isEmpty) return null;

  final pages = <List<OcrLineValue>>[];
  final sizes = <Size>[];
  var script = ScriptValue.unknown;
  for (final path in paths) {
    final size = await _imageSize(path);
    final (lines, read) = await _recognizeAnyScript(path, size);
    pages.add(lines);
    sizes.add(size);
    // The first page that resolved to something names the capture. Pages of
    // one document are in one script far more often than not.
    if (script == ScriptValue.unknown) script = read;
  }
  return ScanCapture(
    pages: pages,
    pageImagePaths: paths,
    pageSizes: sizes,
    guided: guided,
    script: script,
  );
}

/// The image's pixel size, read from its header.
///
/// `ImageDescriptor` parses the dimensions out of the encoded bytes without
/// decoding the pixels, which matters when a ten-page scan would otherwise
/// mean ten full-resolution bitmaps just to learn how tall the paper was.
/// Returns [Size.zero] when the header cannot be read, which the core takes as
/// "unknown" rather than guessing.
Future<Size> _imageSize(String path) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  try {
    buffer = await ui.ImmutableBuffer.fromFilePath(path);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    return Size(descriptor.width.toDouble(), descriptor.height.toDouble());
  } catch (_) {
    return Size.zero;
  } finally {
    descriptor?.dispose();
    buffer?.dispose();
  }
}

/// Returns the captured page paths and whether the guided flow produced them.
Future<(List<String>, bool)> _capturePages(ScanSource source) async {
  if (source == ScanSource.document && guidedScanSupported) {
    try {
      final paths = await _scanDocument();
      // An empty result means the user dismissed the scanner.
      return (paths, true);
    } catch (_) {
      // Play Services missing, too old, or the module could not install.
      // A plain photo still scans, just without the straightening.
    }
  }
  final picked = await _pickImage(
    source == ScanSource.gallery ? ImageSource.gallery : ImageSource.camera,
  );
  return (picked == null ? <String>[] : <String>[picked], false);
}

Future<List<String>> _scanDocument() async {
  final scanner = DocumentScanner(
    options: DocumentScannerOptions(
      // `full` gives edge detection, perspective correction, cropping and the
      // cleanup filters — the whole point of using this over a raw photo.
      mode: ScannerMode.full,
      pageLimit: maxScanPages,
      isGalleryImport: true,
    ),
  );
  try {
    final result = await scanner.scanDocument();
    return result.images ?? const [];
  } finally {
    await scanner.close();
  }
}

Future<String?> _pickImage(ImageSource source) async {
  try {
    final picked = await _picker.pickImage(
      source: source,
      // Downscaling hurts recognition of small print, so the full capture is
      // used; ML Kit does its own scaling internally.
      imageQuality: 100,
    );
    return picked?.path;
  } catch (error) {
    throw ScanFailedException('Could not open the camera or photos: $error');
  }
}

/// Read a page, falling back to the other scripts only when it looks as though
/// the wrong model was used.
///
/// The Latin model shown a Japanese page does not fail — it returns a thin
/// scatter of plausible Latin letters, which nothing downstream can tell from
/// a genuinely sparse page. So the reading is scored by the core, and only a
/// suspect score buys the expensive path of running the other four models over
/// the same image and asking the core which of them read it best.
///
/// Every decision here is the core's; this function only runs the models.
Future<(List<OcrLineValue>, ScriptValue)> _recognizeAnyScript(
  String path,
  Size size,
) async {
  final latin = await _recognize(path);
  final page = (lines: latin, width: size.width, height: size.height);
  final firstTry = scoreScriptReading(script: ScriptValue.latin, page: page);
  if (!readingLooksWrong(firstTry)) {
    return (
      await _reReadPrepared(path, page, TextRecognitionScript.latin),
      ScriptValue.latin,
    );
  }

  final readings = <({ScriptValue script, OcrPageValue page})>[
    (script: ScriptValue.latin, page: page),
  ];
  for (final (recognizer, script) in _scripts.skip(1)) {
    try {
      final lines = await _recognize(path, recognizer);
      readings.add((
        script: script,
        page: (lines: lines, width: size.width, height: size.height),
      ));
    } catch (_) {
      // A model that will not load is one candidate fewer, not a failure.
    }
  }

  final choice = chooseScriptReading(readings: readings);
  if (choice.chosen < 0 || choice.chosen >= readings.length) {
    return (latin, ScriptValue.latin);
  }
  final won = readings[choice.chosen];
  return (
    await _reReadPrepared(path, won.page, _modelFor(won.script)),
    choice.script,
  );
}

/// The recognizer that reads a given script, for re-running the model that
/// already won on this page. Defaults to Latin, which is the model the reading
/// would have come from anyway.
TextRecognitionScript _modelFor(ScriptValue script) {
  for (final (recognizer, value) in _scripts) {
    if (value == script) return recognizer;
  }
  return TextRecognitionScript.latin;
}

/// Read the page a second time from a better image, and keep the better result.
///
/// This is where character accuracy is actually won. Everything downstream
/// works on boxes the model has already emitted and cannot recover a glyph the
/// model misread off a tilted, small or badly lit photograph. So the core is
/// asked whether a different *image* of this page is worth producing, and if it
/// is, the same model reads it again.
///
/// The retry is a candidate, never a replacement: preprocessing can also make a
/// page worse, so both readings are scored and the original holds a tie. The
/// cost of a page that did not improve is the time spent, not text lost.
Future<List<OcrLineValue>> _reReadPrepared(
  String path,
  OcrPageValue first,
  TextRecognitionScript model,
) async {
  final prepared = await preparePageForRecognition(path: path, page: first);
  if (prepared == null) return first.lines;
  try {
    final lines = await _recognize(prepared.path, model);
    final retry = (
      // The boxes come back in prepared-image pixels; everything downstream
      // expects source pixels, and the page's own attachment is the source.
      lines: mapPreparedLinesToSource(lines: lines, prepare: prepared.plan),
      width: first.width,
      height: first.height,
    );
    final choice = choosePageReading(readings: [first, retry]);
    return choice.chosen == 1 ? retry.lines : first.lines;
  } catch (_) {
    return first.lines;
  } finally {
    await _discardPrepared(prepared.path);
  }
}

/// Delete a prepared image and the temporary directory holding it. A failure to
/// clean up is not worth surfacing; the system clears its own temp space.
Future<void> _discardPrepared(String path) async {
  try {
    await File(path).parent.delete(recursive: true);
  } catch (_) {}
}

Future<List<OcrLineValue>> _recognize(
  String path, [
  TextRecognitionScript script = TextRecognitionScript.latin,
]) async {
  final RecognizedText recognized;
  try {
    recognized = await _sharedRecognizer(script).processImage(
      InputImage.fromFilePath(path),
    );
  } catch (error) {
    throw ScanFailedException('Could not read that image: $error');
  }

  final lines = <OcrLineValue>[];
  for (
    var blockIndex = 0;
    blockIndex < recognized.blocks.length;
    blockIndex++
  ) {
    for (final line in recognized.blocks[blockIndex].lines) {
      final box = line.boundingBox;
      lines.add((
        text: line.text,
        left: box.left.toDouble(),
        top: box.top.toDouble(),
        right: box.right.toDouble(),
        bottom: box.bottom.toDouble(),
        blockIndex: blockIndex,
        confidence: line.confidence,
      ));
    }
  }
  return lines;
}

/// Recognize an image already on disk, without capturing anything.
///
/// This is what lets the library be read as well as the camera: a photograph
/// attached to a note months ago goes through the identical recognizer and
/// comes back as the same positioned lines a fresh scan would.
///
/// Returns null when the file cannot be read as an image, which on a mixed bag
/// of old attachments is an ordinary outcome rather than an error.
///
/// Takes the same script path a fresh capture does. A library is exactly where
/// a stray photograph in another alphabet turns up, and reading one only with
/// the Latin model would file it as empty rather than as unread.
Future<OcrPageValue?> recognizeImageFile(String path) async {
  if (!scanningSupported) {
    throw const ScanUnsupportedException(
      'Recognition needs Android or iOS.',
    );
  }
  try {
    final size = await _imageSize(path);
    final (lines, _) = await _recognizeAnyScript(path, size);
    return (lines: lines, width: size.width, height: size.height);
  } catch (_) {
    return null;
  }
}

/// Release the model. Called when the scan screen closes.
Future<void> disposeRecognizer() async {
  for (final recognizer in _recognizers.values) {
    await recognizer.close();
  }
  _recognizers.clear();
}
