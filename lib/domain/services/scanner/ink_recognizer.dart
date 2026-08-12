export 'ink_recognizer_stub.dart'
    if (dart.library.io) 'ink_recognizer_mlkit.dart';

/// One point of a handwritten stroke, in the coordinate space of whatever the
/// user wrote on. [t] is milliseconds since the stroke began — the recognizer
/// uses timing as evidence, so writing speed and pauses genuinely improve the
/// reading.
class InkPoint {
  const InkPoint(this.x, this.y, this.t);
  final double x;
  final double y;
  final int t;
}

/// One continuous mark: pen down, move, pen up.
class InkStroke {
  const InkStroke(this.points);
  final List<InkPoint> points;

  bool get isEmpty => points.isEmpty;
}

/// A reading of some handwriting, with the alternatives that lost.
///
/// Handwriting is genuinely ambiguous, far more so than print, so the runners
/// up are worth keeping: offering "clarity" when the user wrote "chanty" is a
/// better repair than making them retype the word.
class InkReading {
  const InkReading({required this.text, required this.alternatives});

  final String text;

  /// Other candidates, best first, excluding [text].
  final List<String> alternatives;

  bool get isEmpty => text.isEmpty;
}

/// Thrown when the language model is not on the device yet.
class InkModelMissingException implements Exception {
  const InkModelMissingException(this.languageCode);
  final String languageCode;

  @override
  String toString() =>
      'The handwriting model for $languageCode has not been downloaded.';
}

/// Thrown when recognition fails for a reason worth showing.
class InkRecognitionException implements Exception {
  const InkRecognitionException(this.message);
  final String message;

  @override
  String toString() => message;
}
