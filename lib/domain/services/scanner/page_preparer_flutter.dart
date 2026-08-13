import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:ui' show Canvas, Color, FilterQuality, Offset, Paint, Rect;

import '../../../core/native/oblix_core.dart';
import 'page_preparer.dart';

/// Width the histogram is sampled at. The shape of a page's tonal range is a
/// property of the paper and the light, not of the resolution, so a thumbnail
/// answers the question a full decode would — for about a thousandth of the
/// pixels.
const int _sampleWidth = 240;

/// Cells across the thumbnail when sampling how the light fell on the page.
///
/// Coarse on purpose. This has to separate "one side is in shadow" from "the
/// page is evenly lit", which is a question about the whole sheet; a fine grid
/// would start reporting the difference between a paragraph and a margin.
const int _lightingTiles = 6;

/// Corners exposed by rotating a page are filled with paper white rather than
/// left transparent. The recognizer sees a flattened image, and transparent
/// black wedges along the edges are ink as far as it is concerned.
const Color _paper = Color(0xFFFFFFFF);

/// Build a better image for a second recognition pass, or null when this page
/// is not worth one.
///
/// Every judgement here belongs to [`api/prepare.rs`]: what the page's tilt and
/// print size are, whether either is worth acting on, and what transform and
/// colour matrix to use. This function decodes, draws and encodes.
///
/// Returns null rather than throwing when anything goes wrong. A retry is an
/// improvement on a reading that already exists, so failing to produce one is a
/// missed opportunity and not an error worth showing anybody.
Future<PreparedPage?> preparePageForRecognition({
  required String path,
  required OcrPageValue page,
}) async {
  try {
    final plan = planPagePrepare(
      measure: measurePage(page),
      sample: await samplePageLuma(path),
      width: page.width,
      height: page.height,
    );
    if (!plan.worthwhile) return null;

    final written = await _render(path: path, plan: plan);
    if (written == null) return null;
    return PreparedPage(path: written, plan: plan);
  } catch (_) {
    return null;
  }
}

/// Build every image the core thinks this page is worth reading again from.
///
/// The single plan above fuses its corrections into one bitmap, which can only
/// be accepted or rejected whole. These are alternatives — a straightened page,
/// the same page lit per region, the page turned upright — offered so that the
/// reading of each can be judged on its own. `reading` is how the first pass
/// scored, which is what the core weighs the corrections it cannot see in the
/// geometry against.
///
/// Images that fail to draw are dropped rather than reported: a candidate that
/// could not be built is one fewer option, not an error.
Future<List<PreparedPage>> prepareCandidatesForRecognition({
  required String path,
  required OcrPageValue page,
  required PageReadingScoreValue reading,
}) async {
  try {
    final plans = planPageCandidates(
      measure: measurePage(page),
      sample: await samplePageLuma(path),
      width: page.width,
      height: page.height,
      reading: reading,
    );
    final prepared = <PreparedPage>[];
    for (final plan in plans) {
      final written = await _render(path: path, plan: plan);
      if (written != null) {
        prepared.add(PreparedPage(path: written, plan: plan));
      }
    }
    return prepared;
  } catch (_) {
    return const [];
  }
}

/// The page's brightness distribution, or an empty sample when it cannot be
/// read.
Future<PageLumaSampleValue> samplePageLuma(String path) async {
  ui.Codec? codec;
  ui.Image? image;
  try {
    final bytes = await File(path).readAsBytes();
    codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: _sampleWidth,
      allowUpscaling: false,
    );
    image = (await codec.getNextFrame()).image;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return emptyLumaSample;

    final pixels = data.buffer.asUint8List();
    final width = image.width;
    final histogram = Uint32List(256);
    // Running totals per cell, divided out at the end. Summing and dividing
    // beats keeping a histogram per tile: the core only wants each cell's
    // average brightness, not its distribution.
    final tileTotals = Uint64List(_lightingTiles * _lightingTiles);
    final tileCounts = Uint32List(_lightingTiles * _lightingTiles);
    var counted = 0;
    for (var index = 0; index + 3 < pixels.length; index += 4) {
      // Fully transparent pixels are padding, not paper. Anything else is
      // taken at face value: a scan is opaque, so premultiplication by an
      // alpha of 255 is the identity.
      if (pixels[index + 3] == 0) continue;
      final luma =
          0.2126 * pixels[index] +
          0.7152 * pixels[index + 1] +
          0.0722 * pixels[index + 2];
      final level = luma.round().clamp(0, 255);
      histogram[level]++;
      counted++;

      final pixel = index ~/ 4;
      final column = (pixel % width) * _lightingTiles ~/ width;
      final row = (pixel ~/ width) * _lightingTiles ~/ image.height;
      final cell =
          row.clamp(0, _lightingTiles - 1) * _lightingTiles +
          column.clamp(0, _lightingTiles - 1);
      tileTotals[cell] += level;
      tileCounts[cell]++;
    }
    if (counted == 0) return emptyLumaSample;

    final tiles = Uint32List(tileTotals.length);
    for (var cell = 0; cell < tiles.length; cell++) {
      // A cell that caught no opaque pixels has no brightness to report. The
      // core reads a wrong-length tile list as no sample at all, so the whole
      // grid is dropped rather than filled with a guessed level.
      if (tileCounts[cell] == 0) {
        return (
          histogram: histogram,
          tiles: Uint32List(0),
          tileColumns: 0,
          tileRows: 0,
        );
      }
      tiles[cell] = tileTotals[cell] ~/ tileCounts[cell];
    }
    return (
      histogram: histogram,
      tiles: tiles,
      tileColumns: _lightingTiles,
      tileRows: _lightingTiles,
    );
  } catch (_) {
    return emptyLumaSample;
  } finally {
    image?.dispose();
    codec?.dispose();
  }
}

/// Draw the source through the plan and write the result as a PNG.
Future<String?> _render({
  required String path,
  required PagePrepareValue plan,
}) async {
  ui.Codec? codec;
  ui.Image? source;
  ui.Picture? picture;
  ui.Image? prepared;
  try {
    codec = await ui.instantiateImageCodec(await File(path).readAsBytes());
    source = (await codec.getNextFrame()).image;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, plan.outWidth.toDouble(), plan.outHeight.toDouble()),
      Paint()..color = _paper,
    );
    canvas.transform(_matrix4(plan.transform));
    canvas.drawImage(
      source,
      Offset.zero,
      Paint()
        // Cubic sampling, which is the whole point when the plan is an
        // enlargement: nearest-neighbour would upscale the aliasing too.
        ..filterQuality = FilterQuality.high
        ..colorFilter = ui.ColorFilter.matrix(
          plan.colorMatrix.map((value) => value.toDouble()).toList(),
        ),
    );
    picture = recorder.endRecording();

    prepared = await picture.toImage(plan.outWidth, plan.outHeight);
    final encoded = plan.localContrast
        ? await _levelledPng(prepared)
        : (await prepared.toByteData(
            format: ui.ImageByteFormat.png,
          ))?.buffer.asUint8List();
    if (encoded == null) return null;

    final directory = await Directory.systemTemp.createTemp('oblix_prepared_');
    final file = File('${directory.path}/page.png');
    await file.writeAsBytes(encoded, flush: true);
    return file.path;
  } catch (_) {
    return null;
  } finally {
    prepared?.dispose();
    picture?.dispose();
    source?.dispose();
    codec?.dispose();
  }
}

/// Even out the drawn page's lighting, then encode it.
///
/// The pixels make a round trip through the core because the correction is a
/// per-region one, and a `ColorFilter` is a single curve over the whole bitmap
/// — there is no way to express "read this corner's own black point" as a
/// matrix. So this is the same division of labour as the rest of the module,
/// one step lower down: the platform decodes, draws and encodes, and every
/// judgement about what the pixels should become is the core's.
///
/// Returns null when the bitmap cannot be read back, which leaves the caller
/// with no candidate rather than with an unlevelled one.
Future<Uint8List?> _levelledPng(ui.Image image) async {
  // `rawRgba` is premultiplied, which the core's unpremultiplied arithmetic
  // would be wrong about — except that this bitmap cannot contain a
  // transparent pixel. [_render] fills the whole output with paper before
  // drawing, so every alpha is 255 and the two forms are identical.
  final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (raw == null) return null;
  final levelled = normalizePageContrast(
    pixels: raw.buffer.asUint8List(),
    width: image.width,
    height: image.height,
  );

  final buffer = await ui.ImmutableBuffer.fromUint8List(levelled);
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? levelledImage;
  try {
    descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: image.width,
      height: image.height,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    codec = await descriptor.instantiateCodec();
    levelledImage = (await codec.getNextFrame()).image;
    final encoded = await levelledImage.toByteData(
      format: ui.ImageByteFormat.png,
    );
    return encoded?.buffer.asUint8List();
  } finally {
    levelledImage?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}

/// Widen the core's 2D affine into the 4x4 column-major matrix `Canvas` takes.
///
/// The core emits `[a, b, c, d, tx, ty]` for `x' = a*x + c*y + tx`, which is
/// the top-left 2x2 plus a translation column — the same convention a 2D
/// graphics matrix uses, so this only inserts the untouched z row and column.
Float64List _matrix4(Float32List affine) {
  final matrix = Float64List(16);
  matrix[0] = affine[0]; // a
  matrix[1] = affine[1]; // b
  matrix[4] = affine[2]; // c
  matrix[5] = affine[3]; // d
  matrix[12] = affine[4]; // tx
  matrix[13] = affine[5]; // ty
  matrix[10] = 1;
  matrix[15] = 1;
  return matrix;
}
