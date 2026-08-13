import '../../../core/native/crdt_types.dart';
import 'page_preparer.dart';

/// Web build. Nothing here recognizes a page, so nothing here prepares one for
/// recognition either. Reports "no better image available" rather than throwing:
/// a prepared retry is an optimization, and the caller's fallback — keep the
/// reading you already have — is exactly right on a platform with no reading.
Future<PreparedPage?> preparePageForRecognition({
  required String path,
  required OcrPageValue page,
}) async => null;

Future<List<PreparedPage>> prepareCandidatesForRecognition({
  required String path,
  required OcrPageValue page,
  required PageReadingScoreValue reading,
}) async => const [];

Future<PageLumaSampleValue> samplePageLuma(String path) async =>
    emptyLumaSample;
