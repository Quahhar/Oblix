import 'package:flutter_test/flutter_test.dart';
import 'package:oblix/domain/services/collaboration_session.dart';

void main() {
  test('offline close does not claim an unobserved canonical value', () async {
    final session = CollaborationSession(
      noteId: 'note-offline-close',
      readTitle: () => 'Local title',
      readContent: () => 'Local body',
      onSnapshot: (_) {},
      onStateChanged: () {},
    );

    final result = await session.close();
    expect(result.canonicalConfirmed, isFalse);
    expect(result.title, result.canonicalTitle);
    expect(result.content, result.canonicalContent);
  });

  test('first snapshot preserves text typed while connecting', () async {
    var title = 'Server title';
    var content = 'Body';
    late CollaborationSession session;
    session = CollaborationSession(
      noteId: 'note-1',
      readTitle: () => title,
      readContent: () => content,
      onSnapshot: (snapshot) {
        title = snapshot.editorTitle;
        content = snapshot.editorContent;
      },
      onStateChanged: () {},
    );

    title = 'Typed while connecting';
    session.queueLocalEdit('title');
    session.debugReceive({
      'type': 'snapshot',
      'title': 'Server title',
      'content': 'Body',
      'role': 'editor',
      'revision': 0,
      'epoch': 'epoch-1',
    });

    expect(title, 'Typed while connecting');
    expect(session.debugHasPending, isTrue);
    final operationId = session.debugPendingOperationId;

    // A matching canonical acknowledgement settles the pending edit.
    session.debugReceive({
      'type': 'ack',
      'operation_id': operationId,
      'title': title,
      'content': content,
      'role': 'editor',
      'revision': 1,
      'epoch': 'epoch-1',
    });
    await session.close();
  });

  test('own title acknowledgement preserves newer content typing', () async {
    var title = 'A';
    var content = 'B';
    late CollaborationSession session;
    session = CollaborationSession(
      noteId: 'note-2',
      readTitle: () => title,
      readContent: () => content,
      onSnapshot: (snapshot) {
        title = snapshot.editorTitle;
        content = snapshot.editorContent;
      },
      onStateChanged: () {},
    );
    session.debugReceive({
      'type': 'snapshot',
      'title': title,
      'content': content,
      'role': 'editor',
      'revision': 0,
      'epoch': 'epoch-1',
    });

    title = 'AX';
    session.queueLocalEdit('title');
    session.flushNow();
    final operationId = session.debugPendingOperationId;
    expect(operationId, isNotNull);

    content = 'BC';
    session.queueLocalEdit('content');
    session.debugReceive({
      'type': 'edit',
      'operation_id': operationId,
      'field': 'title',
      'delta': [
        {'retain': 1},
        {'insert': 'X'},
      ],
      'revision': 1,
      'epoch': 'epoch-1',
    });

    expect(title, 'AX');
    expect(content, 'BC');
    expect(session.debugHasPending, isTrue);
    final contentOperationId = session.debugPendingOperationId;

    session.debugReceive({
      'type': 'ack',
      'operation_id': operationId,
      'title': title,
      'content': 'B',
      'revision': 1,
      'epoch': 'epoch-1',
    });
    expect(session.debugPendingOperationId, contentOperationId);

    session.debugReceive({
      'type': 'ack',
      'operation_id': contentOperationId,
      'title': title,
      'content': content,
      'role': 'editor',
      'revision': 2,
      'epoch': 'epoch-1',
    });
    await session.close();
  });

  test('reconnect retries a stranded operation idempotently', () async {
    var title = 'A';
    var content = '';
    late CollaborationSession session;
    session = CollaborationSession(
      noteId: 'note-3',
      readTitle: () => title,
      readContent: () => content,
      onSnapshot: (snapshot) {
        title = snapshot.editorTitle;
        content = snapshot.editorContent;
      },
      onStateChanged: () {},
    );
    session.debugReceive({
      'type': 'snapshot',
      'title': title,
      'content': content,
      'role': 'editor',
      'revision': 0,
      'epoch': 'epoch-1',
    });

    title = 'AB';
    session.queueLocalEdit('title');
    session.flushNow();
    final strandedId = session.debugPendingOperationId;

    // Keep the exact operation id: if the first frame committed before the
    // connection died, the server returns an idempotent ack; otherwise it
    // applies the same operation once.
    session.debugReceive({
      'type': 'snapshot',
      'title': 'A',
      'content': '',
      'role': 'editor',
      'revision': 0,
      'epoch': 'epoch-1',
    });
    expect(session.debugHasPending, isTrue);
    expect(session.debugPendingOperationId, strandedId);

    session.debugReceive({
      'type': 'ack',
      'operation_id': strandedId,
      'title': title,
      'content': content,
      'role': 'editor',
      'revision': 1,
      'epoch': 'epoch-1',
    });
    await session.close();
  });

  test('remote edit is transformed with debounced local typing', () async {
    var title = 'A';
    var content = '';
    String? acknowledgedField;
    final session = CollaborationSession(
      noteId: 'note-4',
      readTitle: () => title,
      readContent: () => content,
      onSnapshot: (snapshot) {
        title = snapshot.editorTitle;
        content = snapshot.editorContent;
        acknowledgedField = snapshot.acknowledgedField;
      },
      onStateChanged: () {},
    );
    session.debugReceive({
      'type': 'snapshot',
      'title': 'A',
      'content': '',
      'role': 'editor',
      'revision': 0,
      'epoch': 'epoch-1',
    });

    title = 'AX';
    session.queueLocalEdit('title');
    session.debugReceive({
      'type': 'edit',
      'operation_id': 'another-users-operation',
      'field': 'title',
      'delta': [
        {'retain': 1},
        {'insert': 'Y'},
      ],
      'revision': 1,
      'epoch': 'epoch-1',
    });

    // The remote insertion has server priority at the same position, while
    // the unsent local insertion remains present after it.
    expect(title, 'AYX');
    expect(session.debugHasPending, isTrue);
    expect(acknowledgedField, isNull);
    expect(session.debugPendingPayload?['delta'], [
      {'retain': 2},
      {'insert': 'X'},
    ]);

    final operationId = session.debugPendingOperationId;
    session.debugReceive({
      'type': 'edit',
      'operation_id': operationId,
      'field': 'title',
      'delta': [
        {'retain': 2},
        {'insert': 'X'},
      ],
      'revision': 2,
      'epoch': 'epoch-1',
    });
    expect(acknowledgedField, 'title');
    final result = await session.close();
    expect(result.acknowledgedFields, isEmpty);
  });

  test('close drains typing queued behind an in-flight edit', () async {
    var title = 'A';
    var content = '';
    final session = CollaborationSession(
      noteId: 'note-5',
      readTitle: () => title,
      readContent: () => content,
      onSnapshot: (snapshot) {
        title = snapshot.editorTitle;
        content = snapshot.editorContent;
      },
      onStateChanged: () {},
    );
    session.debugReceive({
      'type': 'snapshot',
      'title': 'A',
      'content': '',
      'role': 'editor',
      'revision': 0,
      'epoch': 'epoch-1',
    });

    title = 'AX';
    session.queueLocalEdit('title');
    session.flushNow();
    final firstId = session.debugPendingOperationId;

    title = 'AXB';
    session.queueLocalEdit('title');
    final closing = session.close();
    session.debugReceive({
      'type': 'edit',
      'operation_id': firstId,
      'field': 'title',
      'delta': [
        {'retain': 1},
        {'insert': 'X'},
      ],
      'revision': 1,
      'epoch': 'epoch-1',
    });

    final secondId = session.debugPendingOperationId;
    expect(secondId, isNotNull);
    expect(secondId, isNot(firstId));
    expect(session.debugPendingPayload?['delta'], [
      {'retain': 2},
      {'insert': 'B'},
    ]);

    session.debugReceive({
      'type': 'edit',
      'operation_id': secondId,
      'field': 'title',
      'delta': [
        {'retain': 2},
        {'insert': 'B'},
      ],
      'revision': 2,
      'epoch': 'epoch-1',
    });
    final result = await closing;
    expect(result.drained, isTrue);
    expect(result.acknowledgedFields, {'title'});
    expect(result.canonicalConfirmed, isTrue);
  });

  test('flush waits until a durable offline save is captured', () async {
    var title = 'A';
    var content = '';
    var mayFlush = false;
    final session = CollaborationSession(
      noteId: 'note-save-gate',
      readTitle: () => title,
      readContent: () => content,
      onSnapshot: (snapshot) {
        title = snapshot.editorTitle;
        content = snapshot.editorContent;
      },
      onStateChanged: () {},
      canFlushLocalEdits: () => mayFlush,
    );
    session.debugReceive({
      'type': 'snapshot',
      'title': title,
      'content': content,
      'role': 'editor',
      'revision': 0,
      'epoch': 'epoch-save-gate',
    });

    title = 'AX';
    session.queueLocalEdit('title');
    session.flushNow();
    expect(session.debugHasPending, isFalse);

    mayFlush = true;
    session.flushNow();
    expect(session.debugHasPending, isTrue);
    final operationId = session.debugPendingOperationId;
    session.debugReceive({
      'type': 'ack',
      'operation_id': operationId,
      'title': title,
      'content': content,
      'role': 'editor',
      'revision': 1,
      'epoch': 'epoch-save-gate',
    });
    await session.close();
  });

  test('duplicate resync response cannot clear a newer operation', () async {
    var title = 'A';
    var content = '';
    final session = CollaborationSession(
      noteId: 'note-6',
      readTitle: () => title,
      readContent: () => content,
      onSnapshot: (snapshot) {
        title = snapshot.editorTitle;
        content = snapshot.editorContent;
      },
      onStateChanged: () {},
    );
    session.debugReceive({
      'type': 'snapshot',
      'title': 'A',
      'content': '',
      'role': 'editor',
      'revision': 0,
      'epoch': 'epoch-1',
    });

    title = 'AX';
    session.queueLocalEdit('title');
    session.flushNow();
    final firstOperationId = session.debugPendingOperationId;

    session.debugReceive({
      'type': 'state',
      'revision': 2,
      'epoch': 'epoch-1',
    });
    final requestId = session.debugResyncRequestId;
    expect(requestId, isNotNull);

    // A second gap notification must share the one outstanding request.
    session.debugReceive({
      'type': 'state',
      'revision': 3,
      'epoch': 'epoch-1',
    });
    expect(session.debugResyncRequestId, requestId);

    final response = {
      'type': 'resync',
      'request_id': requestId,
      'title': 'AY',
      'content': '',
      'role': 'editor',
      'revision': 2,
      'epoch': 'epoch-1',
    };
    session.debugReceive(response);
    final rebasedOperationId = session.debugPendingOperationId;
    expect(rebasedOperationId, isNotNull);
    expect(rebasedOperationId, isNot(firstOperationId));
    expect(title, 'AYX');

    // A delayed duplicate describes the already-consumed request and must not
    // erase or replay the newly-created operation.
    session.debugReceive(response);
    expect(session.debugPendingOperationId, rebasedOperationId);
    expect(title, 'AYX');

    session.debugReceive({
      'type': 'ack',
      'operation_id': rebasedOperationId,
      'title': title,
      'content': content,
      'role': 'editor',
      'revision': 3,
      'epoch': 'epoch-1',
    });
    await session.close();
  });

  test('rejected stranded operation rebases from its original baseline', () async {
    var title = 'A';
    var content = '';
    final session = CollaborationSession(
      noteId: 'note-7',
      readTitle: () => title,
      readContent: () => content,
      onSnapshot: (snapshot) {
        title = snapshot.editorTitle;
        content = snapshot.editorContent;
      },
      onStateChanged: () {},
    );
    session.debugReceive({
      'type': 'snapshot',
      'title': 'A',
      'content': '',
      'role': 'editor',
      'revision': 0,
      'epoch': 'epoch-1',
    });

    title = 'AX';
    session.queueLocalEdit('title');
    session.flushNow();
    final strandedId = session.debugPendingOperationId;

    // While disconnected another user inserted Y. The old operation is then
    // rejected (for example after an epoch reset) with a canonical resync.
    session.debugReceive({
      'type': 'snapshot',
      'title': 'AY',
      'content': '',
      'role': 'editor',
      'revision': 1,
      'epoch': 'epoch-2',
    });
    expect(session.debugPendingOperationId, strandedId);
    session.debugReceive({
      'type': 'resync',
      'title': 'AY',
      'content': '',
      'role': 'editor',
      'revision': 1,
      'epoch': 'epoch-2',
    });

    expect(title, 'AYX');
    expect(session.debugPendingOperationId, isNot(strandedId));
    expect(session.debugPendingPayload?['delta'], [
      {'retain': 2},
      {'insert': 'X'},
    ]);
    final rebasedId = session.debugPendingOperationId;
    session.debugReceive({
      'type': 'ack',
      'operation_id': rebasedId,
      'title': title,
      'content': content,
      'role': 'editor',
      'revision': 2,
      'epoch': 'epoch-2',
    });
    await session.close();
  });

  test('close waits for resync before draining newer local text', () async {
    var title = 'A';
    var content = '';
    final session = CollaborationSession(
      noteId: 'note-8',
      readTitle: () => title,
      readContent: () => content,
      onSnapshot: (snapshot) {
        title = snapshot.editorTitle;
        content = snapshot.editorContent;
      },
      onStateChanged: () {},
    );
    session.debugReceive({
      'type': 'snapshot',
      'title': 'A',
      'content': '',
      'role': 'editor',
      'revision': 0,
      'epoch': 'epoch-1',
    });
    session.debugReceive({
      'type': 'state',
      'revision': 1,
      'epoch': 'epoch-1',
    });
    final requestId = session.debugResyncRequestId;

    title = 'AX';
    final closing = session.close();
    session.debugReceive({
      'type': 'resync',
      'request_id': requestId,
      'title': 'AY',
      'content': '',
      'role': 'editor',
      'revision': 1,
      'epoch': 'epoch-1',
    });

    final operationId = session.debugPendingOperationId;
    expect(operationId, isNotNull);
    session.debugReceive({
      'type': 'ack',
      'operation_id': operationId,
      'title': 'AYX',
      'content': '',
      'role': 'editor',
      'revision': 2,
      'epoch': 'epoch-1',
    });
    final result = await closing;
    expect(result.drained, isTrue);
    expect(result.canonicalTitle, 'AYX');
  });

  test('failed close returns the final remote-rebased desired text', () async {
    var title = 'A';
    var content = '';
    final session = CollaborationSession(
      noteId: 'note-9',
      readTitle: () => title,
      readContent: () => content,
      onSnapshot: (snapshot) {
        title = snapshot.editorTitle;
        content = snapshot.editorContent;
      },
      onStateChanged: () {},
    );
    session.debugReceive({
      'type': 'snapshot',
      'title': 'A',
      'content': '',
      'role': 'owner',
      'revision': 0,
      'epoch': 'epoch-1',
    });

    title = 'AX';
    session.queueLocalEdit('title');
    session.flushNow();
    final closing = session.close();
    session.debugReceive({
      'type': 'edit',
      'operation_id': 'remote-operation',
      'field': 'title',
      'delta': [
        {'retain': 1},
        {'insert': 'Y'},
      ],
      'revision': 1,
      'epoch': 'epoch-1',
    });
    session.debugReceive({
      'type': 'access',
      'role': 'revoked',
      'message': 'Access ended',
    });

    final result = await closing;
    expect(result.drained, isFalse);
    expect(result.title, 'AYX');
    expect(result.canonicalTitle, 'AY');
  });

  test('a lost resync response cannot block the session forever', () async {
    var title = 'A';
    var content = '';
    final session = CollaborationSession(
      noteId: 'note-10',
      readTitle: () => title,
      readContent: () => content,
      onSnapshot: (snapshot) {
        title = snapshot.editorTitle;
        content = snapshot.editorContent;
      },
      onStateChanged: () {},
      resyncResponseTimeout: const Duration(milliseconds: 5),
      maxResyncSendAttempts: 2,
    );
    session.debugReceive({
      'type': 'snapshot',
      'title': title,
      'content': content,
      'role': 'editor',
      'revision': 0,
      'epoch': 'epoch-1',
    });
    session.debugReceive({
      'type': 'state',
      'revision': 1,
      'epoch': 'epoch-1',
    });

    expect(session.debugAwaitingResync, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(session.connection, CollaborationConnection.offline);
    expect(session.debugAwaitingResync, isFalse);
    // Equality with the last-known body is not proof of a complete drain when
    // the server already advertised a newer canonical revision.
    expect((await session.close()).drained, isFalse);
  });

  test('room_busy resync rejection wakes close with fallback text', () async {
    var title = 'A';
    var content = '';
    final session = CollaborationSession(
      noteId: 'note-11',
      readTitle: () => title,
      readContent: () => content,
      onSnapshot: (snapshot) {
        title = snapshot.editorTitle;
        content = snapshot.editorContent;
      },
      onStateChanged: () {},
      resyncResponseTimeout: const Duration(milliseconds: 5),
      maxResyncSendAttempts: 2,
    );
    session.debugReceive({
      'type': 'snapshot',
      'title': title,
      'content': content,
      'role': 'editor',
      'revision': 0,
      'epoch': 'epoch-1',
    });
    session.debugReceive({
      'type': 'state',
      'revision': 1,
      'epoch': 'epoch-1',
    });
    final requestId = session.debugResyncRequestId;
    title = 'AX';
    final closing = session.close();

    session.debugReceive({
      'type': 'error',
      'code': 'room_busy',
      'request_id': requestId,
      'message': 'Retry the resync request.',
    });
    expect(session.debugAwaitingResync, isTrue);

    final result = await closing.timeout(const Duration(milliseconds: 250));
    expect(result.drained, isFalse);
    expect(result.title, 'AX');
    expect(result.canonicalTitle, 'A');
  });

  test('a successful resync cancels its retry watchdog', () async {
    var title = 'A';
    var content = '';
    final session = CollaborationSession(
      noteId: 'note-12',
      readTitle: () => title,
      readContent: () => content,
      onSnapshot: (snapshot) {
        title = snapshot.editorTitle;
        content = snapshot.editorContent;
      },
      onStateChanged: () {},
      resyncResponseTimeout: const Duration(milliseconds: 5),
      maxResyncSendAttempts: 1,
    );
    session.debugReceive({
      'type': 'snapshot',
      'title': title,
      'content': content,
      'role': 'editor',
      'revision': 0,
      'epoch': 'epoch-1',
    });
    session.debugReceive({
      'type': 'state',
      'revision': 1,
      'epoch': 'epoch-1',
    });
    final requestId = session.debugResyncRequestId;
    session.debugReceive({
      'type': 'resync',
      'request_id': requestId,
      'title': 'AY',
      'content': '',
      'role': 'editor',
      'revision': 1,
      'epoch': 'epoch-1',
    });

    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(session.connection, CollaborationConnection.live);
    expect(session.debugAwaitingResync, isFalse);
    expect((await session.close()).drained, isTrue);
  });
}
