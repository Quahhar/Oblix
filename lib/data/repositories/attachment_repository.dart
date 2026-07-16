import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import '../../core/db/app_database.dart';
import '../../core/db/meta_dao.dart';
import '../datasources/local/attachment_local_datasource.dart';
import '../datasources/remote/files_remote_datasource.dart';
import '../models/attachment.dart';

/// Outcome of one attachment reconciliation pass.
class AttachmentSyncResult {
  final int uploaded;
  final int deleted;
  final int failed;
  const AttachmentSyncResult({
    this.uploaded = 0,
    this.deleted = 0,
    this.failed = 0,
  });
}

/// Offline-first attachments. [attach] caches the bytes on disk and records a
/// local row immediately (no network on the hot path); [processSync] later
/// uploads anything whose note has reached the server and settles pending
/// deletes. Binaries never go through the JSON outbox — they travel via the
/// multipart /files endpoint.
class AttachmentRepository {
  final AppDatabase _appDb;
  final AttachmentLocalDataSource _local;
  final MetaDao _meta;
  final FilesRemoteDataSource _remote;
  final Uuid _uuid;
  final Future<Directory> Function() _attachmentsDir;

  AttachmentRepository({
    AppDatabase? appDb,
    AttachmentLocalDataSource? local,
    MetaDao? meta,
    FilesRemoteDataSource? remote,
    Uuid? uuid,
    Future<Directory> Function()? attachmentsDir,
  })  : _appDb = appDb ?? AppDatabase.instance,
        _local =
            local ?? AttachmentLocalDataSource(appDb ?? AppDatabase.instance),
        _meta = meta ?? MetaDao(appDb ?? AppDatabase.instance),
        _remote = remote ?? FilesRemoteDataSource(),
        _uuid = uuid ?? const Uuid(),
        _attachmentsDir = attachmentsDir ?? _defaultDir;

  Stream<void> get onChanged => _appDb.onChanged;

  static Future<Directory> _defaultDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(base.path, 'attachments'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<List<Attachment>> listForNote(String noteId) =>
      _local.listForNote(noteId);

  /// Cache [bytes] on disk and record a local attachment on [noteId]. The
  /// upload is deferred to [processSync] (it can't happen until the note
  /// itself has synced, or the server would 404 the note link).
  Future<Attachment> attach({
    required String noteId,
    required List<int> bytes,
    required String originalName,
    String? mimeType,
  }) async {
    final id = _uuid.v4();
    final dir = await _attachmentsDir();
    final path = p.join(dir.path, '$id${p.extension(originalName)}');
    await File(path).writeAsBytes(bytes, flush: true);

    final now = DateTime.now().toUtc();
    final attachment = Attachment(
      id: id,
      noteId: noteId,
      userId: await _meta.getUserId() ?? '',
      originalName: originalName,
      mimeType: mimeType ?? _guessMime(originalName),
      sizeBytes: bytes.length,
      localPath: path,
      createdAt: now,
      updatedAt: now,
    );
    await _local.insert(attachment);
    _appDb.notifyChanged();
    return attachment;
  }

  /// The attachment's bytes, downloading and caching them if this device only
  /// has the server copy. Null if there are neither local nor remote bytes.
  Future<List<int>?> bytesFor(Attachment a) async {
    if (a.hasLocalBytes) {
      final f = File(a.localPath!);
      if (await f.exists()) return f.readAsBytes();
    }
    final remoteId = a.remoteId;
    if (remoteId == null) return null;
    final bytes = await _remote.download(remoteId);
    final dir = await _attachmentsDir();
    final path = p.join(dir.path, '${a.id}${p.extension(a.originalName)}');
    await File(path).writeAsBytes(bytes, flush: true);
    await _local.setLocalPath(a.id, path);
    return bytes;
  }

  /// Ensure the bytes are cached on disk and return the file path, downloading
  /// from the server if this device only had the remote copy. Null if the
  /// bytes are unavailable (offline with no local cache).
  Future<String?> ensureLocalPath(Attachment a) async {
    if (a.hasLocalBytes && await File(a.localPath!).exists()) return a.localPath;
    final bytes = await bytesFor(a);
    if (bytes == null) return null;
    return (await _local.getById(a.id))?.localPath;
  }

  /// Remove an attachment. Local bytes go immediately; if it was uploaded, the
  /// row is tombstoned so [processSync] can delete the server copy (and retry
  /// until that sticks). A never-uploaded attachment is dropped outright.
  Future<void> delete(Attachment a) async {
    if (a.hasLocalBytes) {
      final f = File(a.localPath!);
      if (await f.exists()) await f.delete();
    }
    if (a.isUploaded && a.remoteId != null) {
      await _local.softDelete(a.id);
    } else {
      await _local.hardDelete(a.id);
    }
    _appDb.notifyChanged();
  }

  /// Reconcile attachments with the server: upload local files whose note has
  /// synced, and delete tombstoned ones. Best-effort — a failure is retried on
  /// the next pass. Safe to call after every note sync.
  Future<AttachmentSyncResult> processSync() async {
    var uploaded = 0, deleted = 0, failed = 0;

    for (final a in await _local.pendingUploads()) {
      try {
        final file = File(a.localPath!);
        if (!await file.exists()) {
          // Bytes vanished (e.g. cache cleared) — drop the dangling row.
          await _local.hardDelete(a.id);
          continue;
        }
        final resp = await _remote.upload(
          bytes: await file.readAsBytes(),
          filename: a.originalName,
          mimeType: a.mimeType,
          noteId: a.noteId,
        );
        await _local.markUploaded(
          a.id,
          remoteId: resp['id'] as String,
          filename: resp['filename'] as String? ?? a.filename,
          sizeBytes: resp['size_bytes'] as int? ?? a.sizeBytes,
        );
        uploaded++;
      } catch (_) {
        failed++;
      }
    }

    for (final a in await _local.pendingRemoteDeletes()) {
      try {
        await _remote.delete(a.remoteId!);
        await _local.hardDelete(a.id);
        deleted++;
      } catch (_) {
        failed++;
      }
    }

    if (uploaded > 0 || deleted > 0) _appDb.notifyChanged();
    return AttachmentSyncResult(
      uploaded: uploaded,
      deleted: deleted,
      failed: failed,
    );
  }

  static String _guessMime(String name) {
    switch (p.extension(name).toLowerCase()) {
      case '.png':
        return 'image/png';
      case '.jpg':
      case '.jpeg':
        return 'image/jpeg';
      case '.gif':
        return 'image/gif';
      case '.webp':
        return 'image/webp';
      case '.heic':
        return 'image/heic';
      case '.pdf':
        return 'application/pdf';
      case '.txt':
        return 'text/plain';
      case '.md':
        return 'text/markdown';
      case '.m4a':
        return 'audio/mp4';
      case '.mp3':
        return 'audio/mpeg';
      case '.wav':
        return 'audio/wav';
      case '.mp4':
        return 'video/mp4';
      case '.mov':
        return 'video/quicktime';
      default:
        return 'application/octet-stream';
    }
  }
}
