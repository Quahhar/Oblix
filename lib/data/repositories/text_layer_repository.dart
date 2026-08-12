import 'package:uuid/uuid.dart';

import '../../core/db/app_database.dart';
import '../../core/native/oblix_core.dart';

/// A stored text layer and what it belongs to.
class StoredTextLayer {
  const StoredTextLayer({
    required this.id,
    required this.noteId,
    this.attachmentId,
    required this.source,
    required this.fingerprint,
    required this.layer,
  });

  final String id;
  final String noteId;
  final String? attachmentId;
  final String source;
  final String fingerprint;
  final TextLayerValue layer;
}

/// A scan the library has seen before.
class DuplicateScan {
  const DuplicateScan({required this.noteId, required this.distance});

  final String noteId;

  /// Differing bits between the two fingerprints. Zero is a byte-identical
  /// reading; a handful means the same document read slightly differently.
  final int distance;
}

/// What the recognizer saw, kept beside the note it produced.
///
/// Local-only by design. A text layer is derived from an attachment the device
/// already has, so it never enters the outbox — another device regenerates its
/// own rather than paying to move this one across the network. That also means
/// nothing here needs a CRDT clock: there is no second writer to conflict with.
class TextLayerRepository {
  TextLayerRepository({AppDatabase? database, Uuid? uuid})
    : _appDb = database ?? AppDatabase.instance,
      _uuid = uuid ?? const Uuid();

  final AppDatabase _appDb;
  final Uuid _uuid;

  /// How many recent fingerprints a duplicate check compares against.
  ///
  /// A simhash is compared by Hamming distance, which no index can answer, so
  /// the candidates have to be read and compared in turn. Bounding it keeps
  /// saving a scan constant-time on a library of any size, at the cost of not
  /// noticing that something was also scanned two thousand scans ago — which
  /// is not what the feature is for.
  static const int duplicateSearchDepth = 200;

  Future<String> save({
    required String noteId,
    String? attachmentId,
    required TextLayerValue layer,
  }) async {
    final db = await _appDb.database;
    final id = _uuid.v4();
    final now = DateTime.now().toUtc().toIso8601String();
    await db.insert('text_layers', {
      'id': id,
      'note_id': noteId,
      'attachment_id': attachmentId,
      'source': layer.source,
      'fingerprint': textLayerFingerprint(layer),
      'search_text': textLayerSearchText(layer),
      'encoded': encodeTextLayer(layer),
      'created_at': now,
    });
    return id;
  }

  /// Every layer stored against a note, oldest first.
  ///
  /// A layer that will not decode is skipped rather than thrown: the encoded
  /// blob is derived data, so a corrupt or future-versioned one should cost
  /// the user a highlight, not the note.
  Future<List<StoredTextLayer>> forNote(String noteId) async {
    final db = await _appDb.database;
    final rows = await db.query(
      'text_layers',
      where: 'note_id = ?',
      whereArgs: [noteId],
      orderBy: 'created_at ASC',
    );
    final layers = <StoredTextLayer>[];
    for (final row in rows) {
      final decoded = _decode(row['encoded'] as String?);
      if (decoded == null) continue;
      layers.add(
        StoredTextLayer(
          id: row['id'] as String,
          noteId: row['note_id'] as String,
          attachmentId: row['attachment_id'] as String?,
          source: row['source'] as String? ?? '',
          fingerprint: row['fingerprint'] as String? ?? '',
          layer: decoded,
        ),
      );
    }
    return layers;
  }

  /// Whether this capture has been scanned into the library already.
  ///
  /// Returns the closest match, so the caller can say *which* note it is
  /// rather than only that there is one.
  Future<DuplicateScan?> findDuplicate(
    TextLayerValue layer, {
    String? ignoreNoteId,
  }) async {
    final fingerprint = textLayerFingerprint(layer);
    // An empty page has no fingerprint, and treating two blank scans as
    // duplicates of each other would be nonsense.
    if (fingerprint.isEmpty) return null;

    final db = await _appDb.database;
    final rows = await db.query(
      'text_layers',
      columns: ['note_id', 'fingerprint'],
      where: "fingerprint != ''",
      orderBy: 'created_at DESC',
      limit: duplicateSearchDepth,
    );

    DuplicateScan? closest;
    for (final row in rows) {
      final noteId = row['note_id'] as String;
      if (noteId == ignoreNoteId) continue;
      final other = row['fingerprint'] as String? ?? '';
      if (!textLayerLooksDuplicate(fingerprint, other)) continue;
      final distance = fingerprintDistance(fingerprint, other);
      if (closest == null || distance < closest.distance) {
        closest = DuplicateScan(noteId: noteId, distance: distance);
      }
      if (distance == 0) break;
    }
    return closest;
  }

  /// Where a query sits on the stored pages, for highlighting on the image.
  Future<List<TextLayerHitValue>> findInNote({
    required String noteId,
    required String query,
  }) async {
    final stored = await forNote(noteId);
    return [
      for (final entry in stored)
        ...findInTextLayer(layer: entry.layer, query: query),
    ];
  }

  /// Attachment ids that already carry a layer, so a backfill pass can skip
  /// them without decoding anything.
  Future<Set<String>> recognizedAttachmentIds() async {
    final db = await _appDb.database;
    final rows = await db.query(
      'text_layers',
      columns: ['attachment_id'],
      where: 'attachment_id IS NOT NULL',
    );
    return {
      for (final row in rows) row['attachment_id'] as String,
    };
  }

  Future<void> deleteForNote(String noteId) async {
    final db = await _appDb.database;
    await db.delete('text_layers', where: 'note_id = ?', whereArgs: [noteId]);
  }

  TextLayerValue? _decode(String? encoded) {
    if (encoded == null || encoded.isEmpty) return null;
    try {
      return decodeTextLayer(encoded);
    } on FormatException {
      return null;
    } on StateError {
      // The native core is not loaded — nothing to decode with.
      return null;
    }
  }
}
