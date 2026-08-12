import '../../../core/native/crdt_types.dart';
import 'document_scanner.dart';

/// Web build. There is no on-device recognizer here, so scanning reports
/// itself unavailable rather than pretending to work.
const bool scanningSupported = false;

const bool guidedScanSupported = false;

const int maxScanPages = 1;

Future<ScanCapture?> captureAndRecognize(ScanSource source) async {
  throw const ScanUnsupportedException(
    'Scanning needs the camera on Android or iOS.',
  );
}

Future<OcrPageValue?> recognizeImageFile(String path) async {
  throw const ScanUnsupportedException('Recognition needs Android or iOS.');
}

/// Nothing to release on this platform.
Future<void> disposeRecognizer() async {}
