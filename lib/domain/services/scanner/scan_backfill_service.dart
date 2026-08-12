import 'dart:async';
import 'dart:io';

import '../../../core/db/app_database.dart';
import '../../../core/native/oblix_core.dart';
import '../../../data/repositories/text_layer_repository.dart';
import 'document_scanner.dart';

/// How far a single pass got.
class BackfillProgress {
  const BackfillProgress({
    required this.considered,
    required this.recognized,
    required this.skipped,
    required this.remaining,
  });

  /// Attachments this pass looked at.
  final int considered;

  /// Attachments that produced a text layer.
  final int recognized;

  /// Attachments that could not be read — a missing file, a format the
  /// recognizer would not take, a page with no text on it.
  final int skipped;

  /// Attachments still waiting, so a caller knows whether to run again.
  final int remaining;

  bool get isComplete => remaining == 0;
}

/// Reads the images already in the library.
///
/// Scanning makes new photographs searchable; this makes the old ones
/// searchable too, which is the difference between a camera feature and a
/// library feature. It is the same recognizer and the same text layer — the
/// only difference is that nobody is waiting for the answer.
///
/// Deliberately incremental. A library can hold thousands of images and
/// recognition is not cheap, so a pass takes a bounded [batchSize] and reports
/// what is left rather than blocking on the whole backlog. Nothing here is
/// destructive: it only ever adds a text layer beside an attachment that had
/// none, so an interrupted pass simply resumes.
class ScanBackfillService {
  ScanBackfillService({
    AppDatabase? database,
    TextLayerRepository? textLayers,
  }) : _appDb = database ?? AppDatabase.instance,
       _textLayers = textLayers ?? TextLayerRepository();

  final AppDatabase _appDb;
  final TextLayerRepository _textLayers;

  /// Attachments read in one pass. Chosen so a pass finishes well inside the
  /// time a user might keep the app open, rather than to maximise throughput.
  static const int batchSize = 20;

  bool _running = false;

  /// Whether this device can read its own library at all.
  bool get isSupported => scanningSupported && isRustCoreReady;

  /// Images with no text layer yet.
  Future<int> pendingCount() async {
    final db = await _appDb.database;
    final rows = await db.rawQuery('''
      SELECT COUNT(*) AS pending FROM attachments a
      WHERE a.is_deleted = 0
        AND a.local_path IS NOT NULL AND a.local_path != ''
        AND a.mime_type LIKE 'image/%'
        AND NOT EXISTS (
          SELECT 1 FROM text_layers t WHERE t.attachment_id = a.id
        )
    ''');
    return (rows.first['pending'] as int?) ?? 0;
  }

  /// Recognize up to [batchSize] images that have never been read.
  ///
  /// Reentrant calls return immediately rather than queueing: two passes over
  /// the same rows would recognize the same images twice and race on the
  /// unique index that stops a second layer being stored.
  Future<BackfillProgress> runOnce() async {
    if (!isSupported || _running) {
      return const BackfillProgress(
        considered: 0,
        recognized: 0,
        skipped: 0,
        remaining: 0,
      );
    }
    _running = true;
    try {
      final db = await _appDb.database;
      final rows = await db.rawQuery(
        '''
        SELECT a.id, a.note_id, a.local_path FROM attachments a
        WHERE a.is_deleted = 0
          AND a.local_path IS NOT NULL AND a.local_path != ''
          AND a.mime_type LIKE 'image/%'
          AND NOT EXISTS (
            SELECT 1 FROM text_layers t WHERE t.attachment_id = a.id
          )
        ORDER BY a.created_at DESC
        LIMIT ?
      ''',
        [batchSize],
      );

      var recognized = 0;
      var skipped = 0;
      for (final row in rows) {
        final path = row['local_path'] as String;
        if (!await File(path).exists()) {
          skipped++;
          continue;
        }
        OcrPageValue? page;
        try {
          page = await recognizeImageFile(path);
        } catch (_) {
          page = null;
        }
        // A page with no text is still a completed reading, and storing the
        // empty layer is what stops it being retried on every pass.
        if (page == null) {
          skipped++;
          continue;
        }
        try {
          await _textLayers.save(
            noteId: row['note_id'] as String,
            attachmentId: row['id'] as String,
            layer: buildTextLayer(pages: [page], source: 'library'),
          );
          recognized++;
        } catch (_) {
          skipped++;
        }
      }
      _appDb.notifyChanged();
      return BackfillProgress(
        considered: rows.length,
        recognized: recognized,
        skipped: skipped,
        remaining: await pendingCount(),
      );
    } finally {
      _running = false;
    }
  }

  /// Keep going until the library is read or [maxBatches] passes have run.
  ///
  /// The cap is a stop, not a target: without it a first run on a large
  /// library would hold the recognizer for as long as it took.
  Future<BackfillProgress> drain({int maxBatches = 25}) async {
    var total = const BackfillProgress(
      considered: 0,
      recognized: 0,
      skipped: 0,
      remaining: 0,
    );
    for (var pass = 0; pass < maxBatches; pass++) {
      final progress = await runOnce();
      total = BackfillProgress(
        considered: total.considered + progress.considered,
        recognized: total.recognized + progress.recognized,
        skipped: total.skipped + progress.skipped,
        remaining: progress.remaining,
      );
      if (progress.considered == 0 || progress.isComplete) break;
    }
    return total;
  }
}
