import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_quill_delta/dart_quill_delta.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../core/config/api_config.dart';
import '../../core/network/api_client.dart';
import '../../core/storage/secure_storage.dart';

enum CollaborationConnection { connecting, live, offline, accessEnded, closed }

class CollaborationParticipant {
  final String userId;
  final String clientId;
  final String displayName;
  final String role;

  const CollaborationParticipant({
    required this.userId,
    required this.clientId,
    required this.displayName,
    required this.role,
  });
}

class CollaborationCursor {
  final String clientId;
  final String field;
  final int offset;
  final int extent;

  const CollaborationCursor({
    required this.clientId,
    required this.field,
    required this.offset,
    required this.extent,
  });
}

class CollaborationSnapshot {
  /// Canonical values committed by the server. These are the values that may
  /// be mirrored into the owner's local cache.
  final String title;
  final String content;

  /// Values to display in the editor. They can temporarily differ from the
  /// canonical values while a transformed local operation is waiting to send.
  final String editorTitle;
  final String editorContent;
  final String role;
  final int revision;
  final String epoch;
  final String? acknowledgedField;

  const CollaborationSnapshot({
    required this.title,
    required this.content,
    required this.editorTitle,
    required this.editorContent,
    required this.role,
    required this.revision,
    required this.epoch,
    this.acknowledgedField,
  });

  bool get preserveTitle => editorTitle != title;
  bool get preserveContent => editorContent != content;
}

class CollaborationCloseResult {
  final bool drained;
  final String title;
  final String content;
  final String canonicalTitle;
  final String canonicalContent;
  final String epoch;
  final int revision;
  final Set<String> acknowledgedFields;
  final bool canonicalConfirmed;

  const CollaborationCloseResult({
    required this.drained,
    required this.title,
    required this.content,
    required this.canonicalTitle,
    required this.canonicalContent,
    required this.epoch,
    required this.revision,
    required this.acknowledgedFields,
    required this.canonicalConfirmed,
  });
}

/// One authenticated operational-transform session for a shared note.
///
/// The server orders revisions. A single operation is in flight per client;
/// later typing stays in the controllers and is diffed again after the ack.
class CollaborationSession {
  final String noteId;
  final String Function() readTitle;
  final String Function() readContent;
  final void Function(CollaborationSnapshot snapshot) onSnapshot;
  final void Function() onStateChanged;
  final bool preserveInitialTitle;
  final bool preserveInitialContent;
  final bool Function()? canFlushLocalEdits;

  CollaborationSession({
    required this.noteId,
    required this.readTitle,
    required this.readContent,
    required this.onSnapshot,
    required this.onStateChanged,
    this.preserveInitialTitle = false,
    this.preserveInitialContent = false,
    this.canFlushLocalEdits,
    Duration resyncResponseTimeout = const Duration(seconds: 2),
    int maxResyncSendAttempts = 3,
  }) : assert(resyncResponseTimeout.inMicroseconds > 0),
       assert(maxResyncSendAttempts > 0),
       _resyncResponseTimeout = resyncResponseTimeout,
       _maxResyncSendAttempts = maxResyncSendAttempts,
       _initialTitle = readTitle(),
       _initialContent = readContent(),
       _serverTitle = readTitle(),
       _serverContent = readContent();

  final String clientId = const Uuid().v4();
  final Duration _resyncResponseTimeout;
  final int _maxResyncSendAttempts;
  CollaborationConnection connection = CollaborationConnection.connecting;
  List<CollaborationParticipant> participants = const [];
  Map<String, CollaborationCursor> cursors = const {};
  String role = 'viewer';
  String? lastError;

  WebSocket? _socket;
  StreamSubscription? _subscription;
  Timer? _editDebounce;
  Timer? _reconnectTimer;
  Timer? _pingTimer;
  Timer? _ackTimer;
  Timer? _resyncTimer;
  bool _closed = false;
  bool _closing = false;
  bool _connecting = false;
  bool _hasSnapshot = false;
  bool _reconnectAllowed = true;
  int _generation = 0;
  int _revision = 0;
  String _epoch = '';
  final String _initialTitle;
  final String _initialContent;
  String _serverTitle;
  String _serverContent;
  String? _closingTitle;
  String? _closingContent;
  DateTime _lastServerMessageAt = DateTime.now();
  bool _awaitingResync = false;
  bool _canonicalUncertain = false;
  int _resyncSendAttempts = 0;
  String? _resyncRequestId;
  String? _resyncPendingOperationId;
  Completer<void>? _resyncCompletion;
  String? _discardOnNextResync;
  _PendingEdit? _pending;
  Completer<void>? _pendingCompletion;
  Future<CollaborationCloseResult>? _closeFuture;
  final Set<String> _closingAcknowledgedFields = <String>{};

  bool get canEditOnline =>
      connection == CollaborationConnection.live &&
      (role == 'owner' || role == 'editor');

  Future<void> connect() async {
    if (_closed || _closing || _connecting) return;
    _connecting = true;
    final generation = ++_generation;
    connection = CollaborationConnection.connecting;
    onStateChanged();

    try {
      final token = await _usableAccessToken();
      if (token == null ||
          token.isEmpty ||
          _closed ||
          _closing ||
          generation != _generation) {
        _goOffline(generation);
        return;
      }
      final uri = Uri.parse(
        '${ApiConfig.apiUrl.replaceFirst('https://', 'wss://').replaceFirst('http://', 'ws://')}'
        '/collaboration/notes/$noteId/ws',
      );
      final socket = await WebSocket.connect(
        uri.toString(),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(ApiConfig.connectTimeout);
      if (_closed || _closing || generation != _generation) {
        await socket.close();
        return;
      }

      _socket = socket;
      _lastServerMessageAt = DateTime.now();
      socket.add(jsonEncode({'type': 'hello', 'client_id': clientId}));
      _subscription = socket.listen(
        (raw) => _receive(raw, generation),
        onError: (_) => _goOffline(generation),
        onDone: () => _socketDone(socket, generation),
        cancelOnError: true,
      );
      _pingTimer?.cancel();
      _pingTimer = Timer.periodic(
        const Duration(seconds: 15),
        (_) {
          if (DateTime.now().difference(_lastServerMessageAt) >
              const Duration(seconds: 45)) {
            _goOffline(generation);
            return;
          }
          _send({'type': 'ping'});
        },
      );
    } catch (_) {
      _goOffline(generation);
    } finally {
      if (generation == _generation) _connecting = false;
    }
  }

  Future<String?> _usableAccessToken() async {
    var token = await SecureStorage.getAccessToken();
    if (token == null || token.isEmpty) return null;
    if (!_tokenNeedsRefresh(token)) return token;

    // A normal authenticated request shares Dio's single-flight refresh path.
    try {
      await ApiClient().dio.get('/auth/me');
    } catch (_) {
      // The WebSocket attempt below still determines whether this was merely
      // a temporary network failure.
    }
    token = await SecureStorage.getAccessToken();
    return token;
  }

  bool _tokenNeedsRefresh(String token) {
    try {
      final pieces = token.split('.');
      final payload =
          jsonDecode(
                utf8.decode(base64Url.decode(base64Url.normalize(pieces[1]))),
              )
              as Map<String, dynamic>;
      final expires = payload['exp'] as int?;
      if (expires == null) return true;
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      return expires <= now + 60;
    } catch (_) {
      return true;
    }
  }

  /// Records a controller edit even while the socket is connecting, so the
  /// first canonical snapshot cannot silently replace just-typed text.
  void queueLocalEdit(String field) {
    if (field != 'title' && field != 'content') {
      return;
    }
    if (!canEditOnline) return;
    _editDebounce?.cancel();
    _editDebounce = Timer(const Duration(milliseconds: 120), _flush);
  }

  void flushNow() {
    _editDebounce?.cancel();
    _flush();
  }

  void sendCursor(String field, int offset, int extent) {
    if (connection != CollaborationConnection.live) return;
    if (offset < 0 || extent < 0) return;
    _send({
      'type': 'cursor',
      'field': field,
      'offset': offset,
      'extent': extent,
    });
  }

  String _currentTitle() => _closing ? _closingTitle! : readTitle();

  String _currentContent() => _closing ? _closingContent! : readContent();

  void _flush({bool allowClosing = false}) {
    if (!canEditOnline ||
        (canFlushLocalEdits != null && !canFlushLocalEdits!()) ||
        _pending != null ||
        _awaitingResync ||
        (_closing && !allowClosing) ||
        _closed) {
      return;
    }
    final title = _currentTitle();
    final content = _currentContent();
    String? field;
    String before = '';
    String after = '';
    if (title != _serverTitle) {
      field = 'title';
      before = _serverTitle;
      after = title;
    } else if (content != _serverContent) {
      field = 'content';
      before = _serverContent;
      after = content;
    }
    if (field == null) return;

    final oldDocument = Delta()..insert(before);
    final newDocument = Delta()..insert(after);
    final change = oldDocument.diff(newDocument);
    if (change.isEmpty) return;
    final operationId = const Uuid().v4();
    final payload = <String, dynamic>{
      'type': 'edit',
      'operation_id': operationId,
      'base_revision': _revision,
      'base_epoch': _epoch,
      'field': field,
      'delta': change.toJson(),
    };
    _pending = _PendingEdit(operationId, field, before, after, payload);
    _pendingCompletion = Completer<void>();
    _send(payload);
    _armAckTimeout(operationId);
  }

  void _armAckTimeout(String operationId) {
    _ackTimer?.cancel();
    _ackTimer = Timer(const Duration(seconds: 8), () {
      final pending = _pending;
      if (pending == null ||
          pending.operationId != operationId ||
          !canEditOnline) {
        return;
      }
      pending.retryCount++;
      if (pending.retryCount >= 3) {
        _goOffline(_generation);
        return;
      }
      // Operation IDs are idempotent on the server, so retrying the exact
      // payload is safe whether the previous frame was lost before or after
      // commit.
      _send(pending.payload);
      _armAckTimeout(operationId);
    });
  }

  void _receive(dynamic raw, int generation) {
    if (generation != _generation || _closed) return;
    try {
      _lastServerMessageAt = DateTime.now();
      final message = jsonDecode(raw as String) as Map<String, dynamic>;
      switch (message['type']) {
        case 'snapshot':
          _receiveSnapshot(message);
        case 'edit':
        case 'ack':
        case 'resync':
          _receiveDocument(message);
        case 'presence':
          _receivePresence(message);
        case 'cursor':
          _receiveCursor(message);
        case 'access':
          _receiveAccess(message);
        case 'session_expired':
          lastError =
              message['message']?.toString() ??
              'Your session expired. Reconnecting…';
          onStateChanged();
        case 'state':
          final revision = message['revision'] as int? ?? _revision;
          final epoch = message['epoch']?.toString() ?? _epoch;
          if (revision != _revision || epoch != _epoch) _requestResync();
        case 'error':
          _receiveError(message);
      }
    } catch (_) {
      _requestResync();
    }
  }

  void _receiveSnapshot(Map<String, dynamic> message) {
    _finishResyncRequest(resolved: true);
    final title = message['title'] as String? ?? '';
    final content = message['content'] as String? ?? '';
    final incomingRole = message['role'] as String? ?? 'viewer';
    final mayPreserve = incomingRole == 'owner' || incomingRole == 'editor';
    final currentTitle = _currentTitle();
    final currentContent = _currentContent();
    final oldServerTitle = _serverTitle;
    final oldServerContent = _serverContent;
    final pending = _pending;

    var editorTitle = title;
    var editorContent = content;
    if (mayPreserve) {
      if (!_hasSnapshot) {
        editorTitle = preserveInitialTitle
            ? currentTitle
            : _rebaseLocal(_initialTitle, title, currentTitle);
        editorContent = preserveInitialContent
            ? currentContent
            : _rebaseLocal(_initialContent, content, currentContent);
      } else {
        // A reconnect may race an operation whose commit status is unknown.
        // Keep that field stable and retry the same idempotency key; the
        // resulting edit/ack tells us exactly how to rebase any later typing.
        editorTitle = pending?.field == 'title'
            ? currentTitle
            : _rebaseLocal(oldServerTitle, title, currentTitle);
        editorContent = pending?.field == 'content'
            ? currentContent
            : _rebaseLocal(oldServerContent, content, currentContent);
      }
    }

    _revision = message['revision'] as int? ?? 0;
    _epoch = message['epoch']?.toString() ?? '';
    _serverTitle = title;
    _serverContent = content;
    role = incomingRole;
    connection = CollaborationConnection.live;
    lastError = null;
    _setClosingValues(editorTitle, editorContent);
    _publishSnapshot(
      title: title,
      content: content,
      editorTitle: editorTitle,
      editorContent: editorContent,
    );
    _hasSnapshot = true;
    if (!_closing) onStateChanged();

    if (pending != null && mayPreserve) {
      _pendingCompletion ??= Completer<void>();
      pending.retryCount = 0;
      _send(pending.payload);
      _armAckTimeout(pending.operationId);
    } else {
      if (pending != null) _clearPending();
      _flush(allowClosing: _closing);
    }
  }

  void _receiveDocument(Map<String, dynamic> message) {
    role = message['role']?.toString() ?? role;
    final incomingEpoch = message['epoch']?.toString() ?? _epoch;
    final revision = message['revision'] as int? ?? _revision;
    final operationId = message['operation_id']?.toString();
    final isOwn = operationId != null && operationId == _pending?.operationId;
    final pending = _pending;
    final kind = message['type']?.toString();
    final acknowledgedField =
        (kind == 'edit' || kind == 'ack') && isOwn ? pending?.field : null;
    String? resyncPendingOperationId;
    if (kind == 'resync') {
      final requestId = message['request_id']?.toString();
      if (requestId != null && requestId != _resyncRequestId) {
        // This is a delayed response to an already-consumed request. Applying
        // it could clear a newer edit created after the first response.
        return;
      }
      resyncPendingOperationId = _awaitingResync
          ? _resyncPendingOperationId
          : _pending?.operationId;
      _finishResyncRequest(resolved: true);
    }

    // An idempotent retry can produce a duplicate acknowledgement after the
    // client has already advanced to its next queued operation. It describes
    // the old operation and must never clear or rebase the new one.
    if (kind == 'ack' && !isOwn) return;

    if (kind == 'edit') {
      if (incomingEpoch != _epoch || revision != _revision + 1) {
        _requestResync();
        return;
      }
    } else if (incomingEpoch == _epoch && revision < _revision) {
      if (isOwn) {
        if (_closing && acknowledgedField != null) {
          _closingAcknowledgedFields.add(acknowledgedField);
        }
        _clearPending();
        _publishSnapshot(
          title: _serverTitle,
          content: _serverContent,
          editorTitle: _currentTitle(),
          editorContent: _currentContent(),
          acknowledgedField: acknowledgedField,
        );
        _flush(allowClosing: _closing);
      }
      return;
    }

    final oldServerTitle = _serverTitle;
    final oldServerContent = _serverContent;
    final currentTitle = _currentTitle();
    final currentContent = _currentContent();
    var title = message['title'] as String? ?? _serverTitle;
    var content = message['content'] as String? ?? _serverContent;
    var editorTitle = currentTitle;
    var editorContent = currentContent;
    Delta? serverDelta;
    String? editedField;
    if (kind == 'edit') {
      final delta = message['delta'] as List<dynamic>? ?? const [];
      final field = message['field']?.toString();
      serverDelta = Delta.fromJson(delta);
      editedField = field;
      if (field == 'title') {
        title = _applyPlainTextDelta(title, delta);
      } else if (field == 'content') {
        content = _applyPlainTextDelta(content, delta);
      } else {
        _requestResync();
        return;
      }
    }

    final code = message['code']?.toString();
    final rejectedField =
        (code == 'title_too_long' ||
            code == 'note_too_large' ||
            code == 'read_only')
        ? pending?.field
        : null;

    if (kind == 'edit' && editedField == 'title') {
      if (isOwn && pending?.field == 'title') {
        editorTitle = _rebaseLocal(pending!.value, title, currentTitle);
      } else {
        editorTitle = _rebaseLocal(
          oldServerTitle,
          title,
          currentTitle,
          serverChange: serverDelta,
        );
        if (pending?.field == 'title') {
          pending!.value = _rebaseLocal(
            oldServerTitle,
            title,
            pending.value,
            serverChange: serverDelta,
          );
          pending.baseValue = title;
        }
      }
    } else if (kind == 'edit' && editedField == 'content') {
      if (isOwn && pending?.field == 'content') {
        editorContent = _rebaseLocal(
          pending!.value,
          content,
          currentContent,
        );
      } else {
        editorContent = _rebaseLocal(
          oldServerContent,
          content,
          currentContent,
          serverChange: serverDelta,
        );
        if (pending?.field == 'content') {
          pending!.value = _rebaseLocal(
            oldServerContent,
            content,
            pending.value,
            serverChange: serverDelta,
          );
          pending.baseValue = content;
        }
      }
    } else if (kind == 'ack' && isOwn && pending != null) {
      editorTitle = pending.field == 'title'
          ? _rebaseLocal(pending.value, title, currentTitle)
          : _rebaseLocal(oldServerTitle, title, currentTitle);
      editorContent = pending.field == 'content'
          ? _rebaseLocal(pending.value, content, currentContent)
          : _rebaseLocal(oldServerContent, content, currentContent);
    } else {
      // A resync is a new canonical baseline. Rebase unsent text over it;
      // permanent validation failures deliberately discard the rejected field
      // so they cannot enter an edit/resync retry loop.
      final pendingResync =
          kind == 'resync' &&
          pending != null &&
          pending.operationId == resyncPendingOperationId;
      editorTitle = rejectedField == 'title'
          ? title
          : _rebaseLocal(
              pendingResync && pending.field == 'title'
                  ? pending.baseValue
                  : oldServerTitle,
              title,
              currentTitle,
            );
      editorContent = rejectedField == 'content'
          ? content
          : _rebaseLocal(
              pendingResync && pending.field == 'content'
                  ? pending.baseValue
                  : oldServerContent,
              content,
              currentContent,
            );
    }

    if (kind == 'resync' && _discardOnNextResync != null) {
      if (_discardOnNextResync == 'title') editorTitle = title;
      if (_discardOnNextResync == 'content') editorContent = content;
      _discardOnNextResync = null;
    }
    if (role == 'viewer') {
      editorTitle = title;
      editorContent = content;
    }

    _serverTitle = title;
    _serverContent = content;
    _revision = revision;
    _epoch = incomingEpoch;
    if (isOwn || kind == 'ack') {
      _clearPending();
    } else if (kind == 'resync' &&
        resyncPendingOperationId != null &&
        _pending?.operationId == resyncPendingOperationId) {
      _clearPending();
    }
    if (code != null) {
      lastError = message['message']?.toString() ?? _friendlyError(code);
    }
    if (_closing && acknowledgedField != null) {
      _closingAcknowledgedFields.add(acknowledgedField);
    }
    _setClosingValues(editorTitle, editorContent);
    _publishSnapshot(
      title: title,
      content: content,
      editorTitle: editorTitle,
      editorContent: editorContent,
      acknowledgedField: acknowledgedField,
    );
    _flush(allowClosing: _closing);
  }

  Delta _plainTextDiff(String before, String after) {
    final oldDocument = Delta()..insert(before);
    final newDocument = Delta()..insert(after);
    return oldDocument.diff(newDocument);
  }

  String _rebaseLocal(
    String oldServer,
    String newServer,
    String local, {
    Delta? serverChange,
  }) {
    if (local == oldServer) return newServer;
    final localChange = _plainTextDiff(oldServer, local);
    final canonicalChange =
        serverChange ?? _plainTextDiff(oldServer, newServer);
    final transformedLocal = canonicalChange.transform(localChange, true);
    return _applyPlainTextDelta(newServer, transformedLocal.toJson());
  }

  void _setClosingValues(String title, String content) {
    if (!_closing) return;
    _closingTitle = title;
    _closingContent = content;
  }

  void _publishSnapshot({
    required String title,
    required String content,
    required String editorTitle,
    required String editorContent,
    String? acknowledgedField,
  }) {
    if (_closing) return;
    onSnapshot(
      CollaborationSnapshot(
        title: title,
        content: content,
        editorTitle: editorTitle,
        editorContent: editorContent,
        role: role,
        revision: _revision,
        epoch: _epoch,
        acknowledgedField: acknowledgedField,
      ),
    );
  }

  String _applyPlainTextDelta(String text, List<dynamic> delta) {
    var cursor = 0;
    final output = StringBuffer();
    for (final raw in delta) {
      final operation = Map<String, dynamic>.from(raw as Map);
      if (operation.containsKey('retain')) {
        final count = operation['retain'] as int;
        output.write(text.substring(cursor, cursor + count));
        cursor += count;
      } else if (operation.containsKey('delete')) {
        cursor += operation['delete'] as int;
      } else if (operation.containsKey('insert')) {
        output.write(operation['insert'] as String);
      } else {
        throw const FormatException('Unsupported collaboration delta');
      }
    }
    output.write(text.substring(cursor));
    return output.toString();
  }

  void _receivePresence(Map<String, dynamic> message) {
    participants = [
      for (final raw in message['participants'] as List? ?? const [])
        CollaborationParticipant(
          userId: (raw as Map)['user_id']?.toString() ?? '',
          clientId: raw['client_id']?.toString() ?? '',
          displayName: raw['display_name']?.toString() ?? 'User',
          role: raw['role']?.toString() ?? 'viewer',
        ),
    ];
    final activeIds = participants.map((p) => p.clientId).toSet();
    cursors = Map.unmodifiable(
      Map<String, CollaborationCursor>.from(cursors)
        ..removeWhere((id, _) => !activeIds.contains(id)),
    );
    onStateChanged();
  }

  void _receiveCursor(Map<String, dynamic> message) {
    final remoteClientId = message['client_id']?.toString() ?? '';
    final field = message['field']?.toString() ?? '';
    final offset = message['offset'];
    final extent = message['extent'];
    if (remoteClientId.isEmpty ||
        remoteClientId == clientId ||
        (field != 'title' && field != 'content') ||
        offset is! int ||
        extent is! int) {
      return;
    }
    cursors = Map.unmodifiable({
      ...cursors,
      remoteClientId: CollaborationCursor(
        clientId: remoteClientId,
        field: field,
        offset: offset,
        extent: extent,
      ),
    });
    onStateChanged();
  }

  void _receiveAccess(Map<String, dynamic> message) {
    final nextRole = message['role']?.toString() ?? 'viewer';
    if (nextRole == 'revoked') {
      role = 'viewer';
      lastError =
          message['message']?.toString() ??
          'Your access to this note has ended.';
      _endAccess();
      return;
    }
    role = nextRole;
    if (role == 'viewer') {
      _clearPending();
      // The access event carries no document body. Fetch the canonical state
      // immediately so rejected editor text cannot remain displayed read-only.
      _requestResync();
    }
    if (!_closing) onStateChanged();
  }

  void _receiveError(Map<String, dynamic> message) {
    final code = message['code']?.toString();
    final operationId = message['operation_id']?.toString();
    if (operationId != null && operationId == _pending?.operationId) {
      _discardOnNextResync = _pending?.field;
      _clearPending();
    }
    lastError =
        message['message']?.toString() ??
        _friendlyError(code);
    if (code == 'note_too_large' && !_hasSnapshot) {
      _reconnectAllowed = false;
    }
    if (!_closing) onStateChanged();
    _requestResync();
  }

  String _friendlyError(String? code) => switch (code) {
    'read_only' => 'You have view-only access.',
    'note_too_large' => 'This note is too large to edit live.',
    'title_too_long' => 'Titles can contain at most 500 characters.',
    'invalid_cursor' => 'Live cursor position was rejected.',
    _ => 'A live edit could not be applied.',
  };

  void _requestResync() {
    if (connection != CollaborationConnection.live || _awaitingResync) return;
    _awaitingResync = true;
    _canonicalUncertain = true;
    _resyncRequestId = const Uuid().v4();
    _resyncPendingOperationId = _pending?.operationId;
    _resyncCompletion = Completer<void>();
    _resyncSendAttempts = 0;
    _sendResyncRequest();
  }

  void _sendResyncRequest() {
    final requestId = _resyncRequestId;
    if (!_awaitingResync ||
        requestId == null ||
        connection != CollaborationConnection.live ||
        _closed) {
      return;
    }
    if (_resyncSendAttempts >= _maxResyncSendAttempts) {
      // A response may have been dropped even though the socket still appears
      // healthy. Reconnect to obtain a fresh admission snapshot instead of
      // leaving edits permanently blocked behind _awaitingResync.
      _goOffline(_generation);
      return;
    }
    _resyncSendAttempts++;
    _send({'type': 'resync', 'request_id': requestId});
    if (!_awaitingResync || requestId != _resyncRequestId) return;
    _resyncTimer?.cancel();
    _resyncTimer = Timer(
      _resyncResponseTimeout,
      () => _sendResyncRequest(),
    );
  }

  void _finishResyncRequest({bool resolved = false}) {
    _resyncTimer?.cancel();
    _resyncTimer = null;
    _awaitingResync = false;
    if (resolved) _canonicalUncertain = false;
    _resyncSendAttempts = 0;
    _resyncRequestId = null;
    _resyncPendingOperationId = null;
    final completion = _resyncCompletion;
    _resyncCompletion = null;
    if (completion != null && !completion.isCompleted) completion.complete();
  }

  void _clearPending() {
    _ackTimer?.cancel();
    _ackTimer = null;
    _pending = null;
    final completion = _pendingCompletion;
    _pendingCompletion = null;
    if (completion != null && !completion.isCompleted) completion.complete();
  }

  void _wakePendingWaiter() {
    final completion = _pendingCompletion;
    _pendingCompletion = null;
    if (completion != null && !completion.isCompleted) completion.complete();
  }

  void _send(Map<String, dynamic> message) {
    try {
      _socket?.add(jsonEncode(message));
    } catch (_) {
      _goOffline(_generation);
    }
  }

  void _socketDone(WebSocket socket, int generation) {
    if (generation != _generation || _closed) return;
    if (socket.closeCode == 4403 || socket.closeCode == 4404) {
      lastError ??= socket.closeReason ?? 'This note is no longer available.';
      _endAccess();
      return;
    }
    if (socket.closeCode == 4409) {
      _reconnectAllowed = false;
      lastError ??= 'This note is too large to edit live.';
    }
    _goOffline(generation);
  }

  void _goOffline(int generation) {
    if (_closed || generation != _generation) return;
    _generation++;
    _connecting = false;
    connection = CollaborationConnection.offline;
    final socket = _socket;
    _socket = null;
    unawaited(socket?.close());
    unawaited(_subscription?.cancel());
    _subscription = null;
    _pingTimer?.cancel();
    _ackTimer?.cancel();
    _finishResyncRequest();
    // Preserve the operation itself for reconnect/fallback, but do not leave a
    // closing session asleep on an acknowledgement that can no longer arrive.
    _wakePendingWaiter();
    participants = const [];
    cursors = const {};
    if (!_closing) onStateChanged();
    _reconnectTimer?.cancel();
    if (_reconnectAllowed && !_closing) {
      _reconnectTimer = Timer(const Duration(seconds: 3), connect);
    }
  }

  void _endAccess() {
    if (_closed) return;
    _generation++;
    connection = CollaborationConnection.accessEnded;
    _reconnectTimer?.cancel();
    _pingTimer?.cancel();
    _finishResyncRequest();
    _clearPending();
    participants = const [];
    cursors = const {};
    final socket = _socket;
    _socket = null;
    unawaited(_subscription?.cancel());
    _subscription = null;
    unawaited(socket?.close());
    if (!_closing) onStateChanged();
  }

  Future<CollaborationCloseResult> close() =>
      _closeFuture ??= _performClose();

  Future<CollaborationCloseResult> _performClose() async {
    _editDebounce?.cancel();
    // Capture controller state before the widget disposes. The session can
    // then drain operation A followed by newer edit B without reading a
    // disposed TextEditingController.
    _closingTitle = readTitle();
    _closingContent = readContent();
    _closing = true;
    _closingAcknowledgedFields.clear();
    _flush(allowClosing: true);

    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (canEditOnline &&
        (_pending != null ||
            _awaitingResync ||
            _canonicalUncertain ||
            _closingTitle != _serverTitle ||
            _closingContent != _serverContent)) {
      _flush(allowClosing: true);
      // A pending operation can require the resync before it can be settled,
      // so the canonical response is the first dependency when both exist.
      final completion = _resyncCompletion ?? _pendingCompletion;
      if (completion == null || completion.isCompleted) {
        break;
      }
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) break;
      try {
        await completion.future.timeout(remaining);
      } catch (_) {
        break;
      }
    }
    final drained =
        _pending == null &&
        !_canonicalUncertain &&
        _closingTitle == _serverTitle &&
        _closingContent == _serverContent;
    final result = CollaborationCloseResult(
      drained: drained,
      title: _closingTitle!,
      content: _closingContent!,
      canonicalTitle: _serverTitle,
      canonicalContent: _serverContent,
      epoch: _epoch,
      revision: _revision,
      acknowledgedFields: Set<String>.unmodifiable(
        _closingAcknowledgedFields,
      ),
      canonicalConfirmed: _hasSnapshot,
    );

    _closed = true;
    _generation++;
    connection = CollaborationConnection.closed;
    _reconnectTimer?.cancel();
    _pingTimer?.cancel();
    _ackTimer?.cancel();
    _finishResyncRequest();
    try {
      await _subscription?.cancel();
    } catch (_) {
      // The final captured state is still usable for durable fallback.
    }
    try {
      await _socket?.close();
    } catch (_) {
      // The final captured state is still usable for durable fallback.
    }
    _socket = null;
    _clearPending();
    return result;
  }

  @visibleForTesting
  void debugReceive(Map<String, dynamic> message) {
    _receive(jsonEncode(message), _generation);
  }

  @visibleForTesting
  String? get debugPendingOperationId => _pending?.operationId;

  @visibleForTesting
  String? get debugResyncRequestId => _resyncRequestId;

  @visibleForTesting
  bool get debugAwaitingResync => _awaitingResync;

  @visibleForTesting
  int get debugResyncSendAttempts => _resyncSendAttempts;

  @visibleForTesting
  Map<String, dynamic>? get debugPendingPayload => _pending?.payload;

  @visibleForTesting
  bool get debugHasPending => _pending != null;
}

class _PendingEdit {
  final String operationId;
  final String field;
  String baseValue;
  String value;
  final Map<String, dynamic> payload;
  int retryCount = 0;

  _PendingEdit(
    this.operationId,
    this.field,
    this.baseValue,
    this.value,
    this.payload,
  );
}
