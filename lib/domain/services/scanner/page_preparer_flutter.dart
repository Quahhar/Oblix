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
    final histogram = Uint32List(256);
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
      histogram[luma.round().clamp(0, 255)]++;
      counted++;
    }
    return counted == 0 ? emptyLumaSample : (histogram: histogram);
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
    final encoded = await prepared.toByteData(format: ui.ImageByteFormat.png);
    if (encoded == null) return null;

    final directory = await Directory.systemTemp.createTemp('oblix_prepared_');
    final file = File('${directory.path}/page.png');
    await file.writeAsBytes(encoded.buffer.asUint8List(), flush: true);
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
