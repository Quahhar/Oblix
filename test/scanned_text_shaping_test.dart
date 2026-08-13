import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:oblix/core/native/oblix_core.dart';

/// Page reconstruction lives entirely in `rust/src/api/ocr.rs`, which carries
/// its own test suite — reading order, deskewing, column detection, paragraph
/// reflow, hyphen healing, noise filtering and title extraction.
///
/// Unlike the other migrated algorithms there is deliberately no Dart mirror
/// of it to compare against: scanning needs a recognizer that exists only on
/// Android and iOS, where the native core is always loaded, so a second
/// implementation would be several hundred lines of geometry that nothing
/// runs and that could drift unnoticed. These tests pin the contract that
/// makes that safe — the Dart side must refuse rather than quietly return a
/// different answer when the core is missing.
void main() {
  const line = (
    text: 'anything',
    left: 0.0,
    top: 0.0,
    right: 100.0,
    bottom: 20.0,
    blockIndex: 0,
    confidence: null,
    words: <OcrWordValue>[],
  );

  test('the core is not loaded in unit tests', () {
    expect(isRustCoreReady, isFalse);
  });

  test('shaping refuses without the native core rather than guessing', () {
    expect(
      () => shapeScannedText(lines: const [line]),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('native Oblix core'),
        ),
      ),
    );
  });

  test('an empty page refuses on the same terms, not silently', () {
    // No special-casing that would let an empty scan look like a success.
    expect(() => shapeScannedText(lines: const []), throwsA(isA<StateError>()));
  });

  test('every option reaches the same guarded entry point', () {
    for (final shape in [
      () => shapeScannedText(lines: const [line], minConfidence: 0.9),
      () => shapeScannedText(lines: const [line], preserveLineBreaks: true),
      () => shapeScannedText(lines: const [line], detectColumns: false),
      () => shapeScannedText(lines: const [line], detectStructure: false),
      () => shapeScannedText(lines: const [line], detectTables: false),
      () => shapeScannedText(lines: const [line], stripRunningHeads: false),
      () => shapeScannedText(lines: const [line], healAcrossPages: false),
      () => shapeScannedText(lines: const [line], repairMisreads: false),
      () => shapeScannedText(
        lines: const [line],
        preset: ScanPresetValue.receipt,
      ),
    ]) {
      expect(shape, throwsA(isA<StateError>()));
    }
  });

  test('a whole capture refuses on the same terms as one page', () {
    expect(
      () => shapeScannedPages(
        pages: const [
          (lines: [line], width: 1000.0, height: 1400.0),
        ],
      ),
      throwsA(isA<StateError>()),
    );
  });

  /// Text layers, entity extraction and PDF reading are native-only for the
  /// same reason reconstruction is. What matters is that they *refuse*: a Dart
  /// mirror quietly returning a different answer would be far worse than an
  /// error, because a wrong redaction box or a missed duplicate is invisible.
  test(
    'the rest of the scanning surface refuses too, rather than guessing',
    () {
      const layer = (
        source: 'camera',
        pages: <TextLayerPageValue>[
          (width: 1000.0, height: 1400.0, lines: <TextLayerLineValue>[]),
        ],
      );
      const pdfPage = (
        runs: <PdfTextRunValue>[
          (text: 'x', x: 0.0, y: 700.0, width: 10.0, height: 10.0),
        ],
        width: 612.0,
        height: 792.0,
        hasImage: false,
      );
      final measure = (
        skewDegrees: 4.0,
        medianLineHeight: 18.0,
        usableLines: 20,
        uprightShare: 1.0,
      );
      final sample = (
        histogram: Uint32List(256),
        tiles: Uint32List(36),
        tileColumns: 6,
        tileRows: 6,
      );
      const reading = (
        score: 10.0,
        characters: 40,
        meanConfidence: 0.8,
        junkShare: 0.1,
        wordShare: 0.8,
      );

      for (final call in <void Function()>[
        () => buildTextLayer(
          pages: const [
            (lines: [line], width: 0.0, height: 0.0),
          ],
          source: 'camera',
        ),
        () => textLayerToPages(layer),
        () => encodeTextLayer(layer),
        () => decodeTextLayer('{"v":1,"src":"camera","p":[]}'),
        () => textLayerSearchText(layer),
        () => findInTextLayer(layer: layer, query: 'anything'),
        () => textLayerRegion(
          layer: layer,
          page: 0,
          left: 0,
          top: 0,
          right: 10,
          bottom: 10,
        ),
        () => textLayerFingerprint(layer),
        () => fingerprintDistance('0', '0'),
        () => textLayerLooksDuplicate('0', '0'),
        () => extractEntities(text: 'call 020 7946 0958'),
        () => findRedactions(layer: layer),
        () => suggestActions(text: 'TOTAL £3.50'),
        () => assessPdfPage(pdfPage),
        () => pdfPagesToOcrPages(pages: const [pdfPage]),
        () => detectScript('anything'),
        () => scoreScriptReading(
          script: ScriptValue.latin,
          page: (lines: const [line], width: 1000.0, height: 1400.0),
        ),
        () => readingLooksWrong((
          script: ScriptValue.latin,
          score: 1.0,
          characters: 10,
          meanConfidence: 0.9,
          coverage: 0.2,
          junkShare: 0.0,
          dominantScript: ScriptValue.latin,
        )),
        () => chooseScriptReading(
          readings: [
            (
              script: ScriptValue.latin,
              page: (lines: const [line], width: 1000.0, height: 1400.0),
            ),
          ],
        ),
        () => measurePage((lines: const [line], width: 1000.0, height: 1400.0)),
        () => planPagePrepare(
          measure: measure,
          sample: sample,
          width: 1000.0,
          height: 1400.0,
        ),
        () => planPageCandidates(
          measure: measure,
          sample: sample,
          width: 1000.0,
          height: 1400.0,
          reading: reading,
        ),
        () => normalizePageContrast(pixels: Uint8List(4), width: 1, height: 1),
        () => mapPreparedLinesToSource(
          lines: const [line],
          prepare: (
            worthwhile: true,
            outWidth: 1000,
            outHeight: 1400,
            transform: Float32List.fromList(const [1, 0, 0, 1, 0, 0]),
            colorMatrix: Float32List(20),
            localContrast: false,
            rotateDegrees: 0.0,
            quarterTurns: 0,
            scale: 1.0,
            reason: 'test',
          ),
        ),
        () => scorePageReading(
          page: (lines: const [line], width: 1000.0, height: 1400.0),
        ),
        () => choosePageReading(
          readings: const [
            (lines: [line], width: 1000.0, height: 1400.0),
          ],
        ),
      ]) {
        expect(call, throwsA(isA<StateError>()));
      }
    },
  );
}
