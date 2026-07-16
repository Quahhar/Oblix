import 'package:equatable/equatable.dart';

/// A file attached to a note, mirrored locally.
///
/// [id] is a stable client-minted local id. [remoteId] is the server's file id,
/// assigned only once the bytes have been uploaded (the server mints file ids —
/// unlike notes, whose ids the client mints). [localPath] is the on-disk cache
/// of the bytes; it is null for a file that exists on the server but hasn't been
/// downloaded to this device yet.
class Attachment extends Equatable {
  final String id;
  final String? remoteId;
  final String noteId;
  final String userId;
  final String filename; // server-generated storage name, once uploaded
  final String originalName; // display name
  final String mimeType;
  final int sizeBytes;
  final String? localPath;
  final bool isUploaded;
  final bool isDeleted;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Attachment({
    required this.id,
    this.remoteId,
    required this.noteId,
    required this.userId,
    this.filename = '',
    required this.originalName,
    this.mimeType = 'application/octet-stream',
    this.sizeBytes = 0,
    this.localPath,
    this.isUploaded = false,
    this.isDeleted = false,
    required this.createdAt,
    required this.updatedAt,
  });

  bool get hasLocalBytes => localPath != null && localPath!.isNotEmpty;
  bool get isImage => mimeType.startsWith('image/');

  Attachment copyWith({
    String? remoteId,
    String? filename,
    String? originalName,
    String? mimeType,
    int? sizeBytes,
    String? localPath,
    bool? isUploaded,
    bool? isDeleted,
    DateTime? updatedAt,
  }) {
    return Attachment(
      id: id,
      remoteId: remoteId ?? this.remoteId,
      noteId: noteId,
      userId: userId,
      filename: filename ?? this.filename,
      originalName: originalName ?? this.originalName,
      mimeType: mimeType ?? this.mimeType,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      localPath: localPath ?? this.localPath,
      isUploaded: isUploaded ?? this.isUploaded,
      isDeleted: isDeleted ?? this.isDeleted,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  /// Build from the server's `FileResponse` shape (a file pulled from /files).
  /// [noteFallback] is used when the server record has no note link.
  factory Attachment.fromServerJson(
    Map<String, dynamic> json, {
    required String localId,
    String noteFallback = '',
  }) {
    final created = DateTime.parse(json['created_at'] as String);
    return Attachment(
      id: localId,
      remoteId: json['id'] as String,
      noteId: (json['note_id'] as String?) ?? noteFallback,
      userId: json['user_id'] as String? ?? '',
      filename: json['filename'] as String? ?? '',
      originalName: json['original_name'] as String? ?? 'file',
      mimeType: json['mime_type'] as String? ?? 'application/octet-stream',
      sizeBytes: json['size_bytes'] as int? ?? 0,
      isUploaded: true,
      isDeleted: json['is_deleted'] as bool? ?? false,
      createdAt: created,
      updatedAt: json['updated_at'] != null
          ? DateTime.parse(json['updated_at'] as String)
          : created,
    );
  }

  @override
  List<Object?> get props => [
    id,
    remoteId,
    noteId,
    originalName,
    mimeType,
    sizeBytes,
    localPath,
    isUploaded,
    isDeleted,
    updatedAt,
  ];
}
