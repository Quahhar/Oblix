import 'ink_recognizer.dart';

/// Web build. Digital ink recognition is an on-device ML Kit model, so it
/// reports itself unavailable rather than pretending to work.
const bool inkRecognitionSupported = false;

Future<bool> isInkModelDownloaded([String languageCode = 'en-US']) async =>
    false;

Future<bool> downloadInkModel([String languageCode = 'en-US']) async => false;

Future<InkReading> recognizeInk(
  List<InkStroke> strokes, {
  String languageCode = 'en-US',
}) async {
  throw const InkRecognitionException(
    'Handwriting recognition needs Android or iOS.',
  );
}

Future<void> disposeInkRecognizer() async {}
