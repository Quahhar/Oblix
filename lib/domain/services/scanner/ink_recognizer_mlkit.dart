import 'dart:io';

import 'package:google_mlkit_digital_ink_recognition/google_mlkit_digital_ink_recognition.dart'
    as mlkit;

import 'ink_recognizer.dart';

/// ML Kit ships Android and iOS only. `dart.library.io` is also true on
/// desktop, so the platform is checked at runtime rather than at import time.
bool get inkRecognitionSupported => Platform.isAndroid || Platform.isIOS;

/// Recognizing handwriting *as it is written* is a different problem from
/// recognizing it in a photograph, and a far more tractable one: the strokes
/// carry order, direction and timing that a picture of the same words has
/// thrown away. That is why this exists and why photographed cursive is not
/// promised — on-device models read live ink well and read pictures of
/// handwriting poorly.
final mlkit.DigitalInkRecognizerModelManager _models =
    mlkit.DigitalInkRecognizerModelManager();

/// Recognizers hold a loaded model, so one is kept per language rather than
/// built per call.
final Map<String, mlkit.DigitalInkRecognizer> _recognizers = {};

Future<bool> isInkModelDownloaded([String languageCode = 'en-US']) async {
  if (!inkRecognitionSupported) return false;
  try {
    return await _models.isModelDownloaded(languageCode);
  } catch (_) {
    return false;
  }
}

/// Fetch the language model. Needs the network once; recognition afterwards is
/// entirely on-device, which is what keeps the feature offline-first.
Future<bool> downloadInkModel([String languageCode = 'en-US']) async {
  if (!inkRecognitionSupported) return false;
  try {
    return await _models.downloadModel(languageCode);
  } catch (_) {
    return false;
  }
}

/// Read handwritten strokes as text.
///
/// Throws [InkModelMissingException] when the language has not been downloaded,
/// rather than silently returning nothing — the caller can then offer to fetch
/// it, which is a very different message from "that was unreadable".
Future<InkReading> recognizeInk(
  List<InkStroke> strokes, {
  String languageCode = 'en-US',
}) async {
  if (!inkRecognitionSupported) {
    throw const InkRecognitionException(
      'Handwriting recognition needs Android or iOS.',
    );
  }
  final usable = strokes.where((stroke) => !stroke.isEmpty).toList();
  if (usable.isEmpty) {
    return const InkReading(text: '', alternatives: []);
  }
  if (!await isInkModelDownloaded(languageCode)) {
    throw InkModelMissingException(languageCode);
  }

  final ink = mlkit.Ink()
    ..strokes = [
      for (final stroke in usable)
        mlkit.Stroke()
          ..points = [
            for (final point in stroke.points)
              mlkit.StrokePoint(x: point.x, y: point.y, t: point.t),
          ],
    ];

  final List<mlkit.RecognitionCandidate> candidates;
  try {
    candidates = await _recognizerFor(languageCode).recognize(ink);
  } catch (error) {
    throw InkRecognitionException('Could not read that handwriting: $error');
  }
  if (candidates.isEmpty) {
    return const InkReading(text: '', alternatives: []);
  }
  return InkReading(
    text: candidates.first.text,
    alternatives: [
      for (final candidate in candidates.skip(1)) candidate.text,
    ],
  );
}

mlkit.DigitalInkRecognizer _recognizerFor(String languageCode) =>
    _recognizers[languageCode] ??= mlkit.DigitalInkRecognizer(
      languageCode: languageCode,
    );

/// Release every loaded model.
Future<void> disposeInkRecognizer() async {
  for (final recognizer in _recognizers.values) {
    await recognizer.close();
  }
  _recognizers.clear();
}
