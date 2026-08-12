import 'dart:io';

const _generatedPath = 'lib/core/native/generated/frb_generated.dart';
const _original = '''    return utf8.decoder.convert(inner);''';
const _replacement = r'''    final decoded = utf8.decoder.convert(inner);
    final startsWithUtf8Bom =
        inner.length >= 3 &&
        inner[0] == 0xef &&
        inner[1] == 0xbb &&
        inner[2] == 0xbf;
    return startsWithUtf8Bom ? '\uFEFF$decoded' : decoded;''';

void main() {
  final file = File(_generatedPath);
  if (!file.existsSync()) {
    stderr.writeln('Missing generated bridge: $_generatedPath');
    exitCode = 1;
    return;
  }

  final source = file.readAsStringSync();
  if (source.contains(_replacement)) {
    stdout.writeln('FRB UTF-8 normalization already applied.');
    return;
  }
  final matches = _original.allMatches(source).length;
  if (matches != 1) {
    stderr.writeln(
      'Expected one FRB UTF-8 decoder site, found $matches. '
      'Review the pinned generator output before updating this normalizer.',
    );
    exitCode = 1;
    return;
  }

  file.writeAsStringSync(source.replaceFirst(_original, _replacement));
  stdout.writeln('Patched FRB UTF-8 decoding to preserve a leading BOM.');
}
