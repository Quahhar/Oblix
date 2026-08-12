import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:oblix/core/native/oblix_core.dart';
import 'package:oblix/core/native/oblix_core_fallback.dart' as dart_oracle;

String _jwt(Map<String, Object?> payload) {
  final encoded = base64Url
      .encode(utf8.encode(jsonEncode(payload)))
      .replaceAll('=', '');
  return 'header.$encoded.signature';
}

void _expectOutboxSummary(
  PendingOutboxSummaryValue actual,
  PendingOutboxSummaryValue expected,
) {
  expect(actual.fields, expected.fields);
  expect(
    actual.updateSeqsByField.keys.toSet(),
    expected.updateSeqsByField.keys.toSet(),
  );
  for (final field in expected.updateSeqsByField.keys) {
    expect(
      actual.updateSeqsByField[field],
      expected.updateSeqsByField[field],
      reason: 'sequence summary for $field',
    );
  }
}

void _expectRetirement(
  OutboxRetirementValue actual,
  OutboxRetirementValue expected,
) {
  expect(actual.changed, expected.changed);
  expect(actual.deleteRow, expected.deleteRow);
  if (!actual.changed || actual.deleteRow) {
    expect(actual.dataJson, expected.dataJson);
    return;
  }
  expect(jsonDecode(actual.dataJson), jsonDecode(expected.dataJson));
}

void _expectSettlement(
  SyncSettlementValue actual,
  SyncSettlementValue expected,
) {
  expect(actual.ackedSeqs, expected.ackedSeqs);
  expect(actual.retrySeqs, expected.retrySeqs);
  expect(actual.pulledCount, expected.pulledCount);
  expect(actual.anythingChanged, expected.anythingChanged);
  expect(actual.continueDraining, expected.continueDraining);
}

void _expectPaths(
  List<NotebookPathValue> actual,
  List<NotebookPathValue> expected,
) {
  expect(actual.map((item) => item.id), expected.map((item) => item.id));
  for (var index = 0; index < expected.length; index++) {
    expect(actual[index].path, expected[index].path);
    expect(actual[index].pathKey, expected[index].pathKey);
  }
}

void _expectTextFiles(
  List<ExportTextFileValue> actual,
  List<ExportTextFileValue> expected,
) {
  expect(actual, hasLength(expected.length));
  for (var index = 0; index < expected.length; index++) {
    expect(actual[index].filename, expected[index].filename);
    expect(actual[index].content, expected[index].content);
  }
}

void main() {
  setUpAll(() async {
    await initializeOblixCore();
  });

  test('portable facade initializes the native Rust core', () {
    expect(isRustCoreReady, isTrue);
  });

  group('clock and timestamp policies', () {
    test('clock stamping matches Dart and preserves map order', () {
      const existing = <String, CrdtClockValue>{
        'future_field': (timestampMicrosUtc: 1, deviceId: 'legacy'),
        'title': (timestampMicrosUtc: 2, deviceId: 'old-device'),
      };
      const fields = ['title', 'content', 'title'];

      final expected = dart_oracle.stampCrdtClockValues(
        existing: existing,
        fields: fields,
        timestampMicrosUtc: 99,
        deviceId: 'phone-😀',
      );
      final actual = stampCrdtClockValues(
        existing: existing,
        fields: fields,
        timestampMicrosUtc: 99,
        deviceId: 'phone-😀',
      );

      expect(actual, expected);
      expect(actual.keys.toList(), ['future_field', 'title', 'content']);
      expect(actual['future_field'], existing['future_field']);
      expect(
        () =>
            actual['another'] = (timestampMicrosUtc: 100, deviceId: 'mutator'),
        throwsUnsupportedError,
      );
    });

    test('logical time, LWW, import clamp and backoff match Dart', () {
      for (final sample in const [
        (now: 5000, previous: null),
        (now: 5000, previous: 4000),
        (now: 5000, previous: 5000),
        (now: 4000, previous: 5000),
      ]) {
        expect(
          nextLogicalTimestampMicros(
            nowMicrosUtc: sample.now,
            previousMicrosUtc: sample.previous,
          ),
          dart_oracle.nextLogicalTimestampMicros(
            nowMicrosUtc: sample.now,
            previousMicrosUtc: sample.previous,
          ),
        );
      }

      for (final sample in const [
        (local: 10, remote: 9),
        (local: 10, remote: 10),
        (local: 10, remote: 11),
      ]) {
        expect(
          remoteTimestampWinsEqual(
            localTimestampMicrosUtc: sample.local,
            remoteTimestampMicrosUtc: sample.remote,
          ),
          dart_oracle.remoteTimestampWinsEqual(
            localTimestampMicrosUtc: sample.local,
            remoteTimestampMicrosUtc: sample.remote,
          ),
        );
      }

      expect(
        clampImportedTimestampMicros(
          timestampMicrosUtc: 120,
          nowMicrosUtc: 100,
        ),
        dart_oracle.clampImportedTimestampMicros(
          timestampMicrosUtc: 120,
          nowMicrosUtc: 100,
        ),
      );
      for (final failures in const [-1, 0, 1, 3, 99]) {
        expect(
          syncBackoffMillis(
            consecutiveFailures: failures,
            baseMillis: 1000,
            maxMillis: 60000,
          ),
          dart_oracle.syncBackoffMillis(
            consecutiveFailures: failures,
            baseMillis: 1000,
            maxMillis: 60000,
          ),
        );
      }
    });
  });

  group('JWT, title, tag and snapshot helpers', () {
    test('JWT subject and refresh policy match the Dart oracle', () {
      final fresh = _jwt({'sub': 'user-😀', 'exp': 1061});
      final expiring = _jwt({'sub': 'user-😀', 'exp': 1060});
      final missingExpiry = _jwt({'sub': 'user-😀'});

      for (final token in [fresh, expiring, missingExpiry, 'malformed']) {
        expect(
          collaborationTokenNeedsRefresh(token, nowSeconds: 1000),
          dart_oracle.collaborationTokenNeedsRefresh(token, nowSeconds: 1000),
          reason: token,
        );
        expect(jwtSubject(token), dart_oracle.jwtSubject(token));
      }
      expect(jwtSubject(fresh), 'user-😀');
      expect(collaborationTokenNeedsRefresh(fresh, nowSeconds: 1000), isFalse);
      expect(
        collaborationTokenNeedsRefresh(expiring, nowSeconds: 1000),
        isTrue,
      );
    });

    test('title, draft, sharing, tag and filename policies stay in parity', () {
      for (final title in const ['', '   ', '  A title  ', 'Untitled', '😀']) {
        expect(
          normalizeTaskTitle(title),
          dart_oracle.normalizeTaskTitle(title),
        );
        expect(
          normalizeNoteTitle(title),
          dart_oracle.normalizeNoteTitle(title),
        );
        expect(
          sanitizeSingleExportStem(title),
          dart_oracle.sanitizeSingleExportStem(title),
        );
      }
      for (final title in const ['\uFEFF', '\uFEFFA title\uFEFF']) {
        expect(
          normalizeTaskTitle(title),
          dart_oracle.normalizeTaskTitle(title),
        );
        expect(
          normalizeNoteTitle(title),
          dart_oracle.normalizeNoteTitle(title),
        );
        expect(
          sanitizeSingleExportStem(title),
          dart_oracle.sanitizeSingleExportStem(title),
        );
      }

      for (final sample in const [
        (title: '', content: ''),
        (title: '  ', content: '\n'),
        (title: '\uFEFF', content: '\uFEFF'),
        (title: 'Title', content: ''),
      ]) {
        expect(
          noteDraftIsEmpty(title: sample.title, content: sample.content),
          dart_oracle.noteDraftIsEmpty(
            title: sample.title,
            content: sample.content,
          ),
        );
        final actualShare = noteShareText(
          title: sample.title,
          content: sample.content,
        );
        final expectedShare = dart_oracle.noteShareText(
          title: sample.title,
          content: sample.content,
        );
        expect(actualShare, expectedShare);
      }

      const rawTags = ' work,ideas, work, 😀,Ideas,,😀 ';
      expect(parseTagNames(rawTags), dart_oracle.parseTagNames(rawTags));
      expect(parseTagNames(rawTags), ['work', 'ideas', '😀', 'Ideas']);

      const bomTags = ' \uFEFFwork\uFEFF,\uFEFFideas\uFEFF ';
      expect(parseTagNames(bomTags), dart_oracle.parseTagNames(bomTags));
      expect(parseTagNames(bomTags), ['work', 'ideas']);

      for (final sample in const [
        (
          lastEpoch: 'epoch-a',
          lastRevision: 4,
          incomingEpoch: 'epoch-a',
          incomingRevision: 4,
        ),
        (
          lastEpoch: 'epoch-a',
          lastRevision: 4,
          incomingEpoch: 'epoch-a',
          incomingRevision: 5,
        ),
        (
          lastEpoch: 'epoch-a',
          lastRevision: 99,
          incomingEpoch: 'epoch-b',
          incomingRevision: 1,
        ),
      ]) {
        expect(
          collaborationSnapshotIsStale(
            lastEpoch: sample.lastEpoch,
            lastRevision: sample.lastRevision,
            incomingEpoch: sample.incomingEpoch,
            incomingRevision: sample.incomingRevision,
          ),
          dart_oracle.collaborationSnapshotIsStale(
            lastEpoch: sample.lastEpoch,
            lastRevision: sample.lastRevision,
            incomingEpoch: sample.incomingEpoch,
            incomingRevision: sample.incomingRevision,
          ),
        );
      }
    });
  });

  group('sync and outbox policies', () {
    test('pending-field summaries and retirement match Dart semantics', () {
      final rows = <PendingOutboxRowValue>[
        (
          seq: 7,
          action: 'update',
          dataJson: jsonEncode({
            'title': 'A',
            'field_clocks': {
              'title': {'timestamp': 't'},
            },
          }),
        ),
        (seq: 8, action: 'update', dataJson: jsonEncode({'content': 'B'})),
        (seq: 9, action: 'create', dataJson: jsonEncode({'title': 'created'})),
        (seq: 10, action: 'update', dataJson: '{broken'),
      ];
      _expectOutboxSummary(
        summarizePendingOutbox(rows),
        dart_oracle.summarizePendingOutbox(rows),
      );

      final payload = jsonEncode({
        'title': 'A',
        'content': 'B',
        'field_clocks': {
          'title': {'timestamp': 'one'},
          'content': {'timestamp': 'two'},
        },
      });
      _expectRetirement(
        retireAcknowledgedOutboxField(dataJson: payload, field: 'title'),
        dart_oracle.retireAcknowledgedOutboxField(
          dataJson: payload,
          field: 'title',
        ),
      );

      final onlyField = jsonEncode({
        'title': 'A',
        'field_clocks': {
          'title': {'timestamp': 'one'},
        },
      });
      _expectRetirement(
        retireAcknowledgedOutboxField(dataJson: onlyField, field: 'title'),
        dart_oracle.retireAcknowledgedOutboxField(
          dataJson: onlyField,
          field: 'title',
        ),
      );
      _expectRetirement(
        retireAcknowledgedOutboxField(dataJson: '{broken', field: 'title'),
        dart_oracle.retireAcknowledgedOutboxField(
          dataJson: '{broken',
          field: 'title',
        ),
      );
    });

    test('batch eligibility and settlement plans match Dart', () {
      const entries = <SyncBatchEntryValue>[
        (seq: 1, entityType: 'note', entityId: 'shared-id'),
        (seq: 2, entityType: 'task', entityId: 'shared-id'),
        (seq: 3, entityType: 'note', entityId: 'other'),
      ];
      const protected = {'shared-id'};
      expect(
        eligibleSyncSequences(entries: entries, protectedNoteIds: protected),
        dart_oracle.eligibleSyncSequences(
          entries: entries,
          protectedNoteIds: protected,
        ),
      );
      expect(
        eligibleSyncSequences(entries: entries, protectedNoteIds: protected),
        [2, 3],
      );

      final scenarios = [
        (
          decided: const {'shared-id'},
          protectedServerNoteSeen: false,
          batchSize: 3,
          pulled: const [1, 2, 3],
          dropped: 0,
        ),
        (
          decided: const <String>{},
          protectedServerNoteSeen: false,
          batchSize: 3,
          pulled: const <int>[],
          dropped: 0,
        ),
        (
          decided: const <String>{},
          protectedServerNoteSeen: true,
          batchSize: 3,
          pulled: const <int>[],
          dropped: 2,
        ),
      ];
      for (final scenario in scenarios) {
        _expectSettlement(
          planSyncSettlement(
            entries: entries,
            decidedEntityIds: scenario.decided,
            protectedServerNoteSeen: scenario.protectedServerNoteSeen,
            batchSize: scenario.batchSize,
            pulledEntityCounts: scenario.pulled,
            droppedCount: scenario.dropped,
          ),
          dart_oracle.planSyncSettlement(
            entries: entries,
            decidedEntityIds: scenario.decided,
            protectedServerNoteSeen: scenario.protectedServerNoteSeen,
            batchSize: scenario.batchSize,
            pulledEntityCounts: scenario.pulled,
            droppedCount: scenario.dropped,
          ),
        );
      }
    });
  });

  group('notebook hierarchy policies', () {
    test('paths, cycles, UTF-16 keys and ancestor selection match Dart', () {
      const nodes = <NotebookNodeValue>[
        (id: 'root', name: 'Work', parentId: null),
        (id: 'leaf', name: '📁 Projects', parentId: 'root'),
        (id: 'deep', name: '2026', parentId: 'leaf'),
        (id: 'orphan', name: 'Loose', parentId: 'missing'),
        (id: 'cycle-a', name: 'A', parentId: 'cycle-b'),
        (id: 'cycle-b', name: 'B', parentId: 'cycle-a'),
      ];

      final expected = dart_oracle.resolveNotebookPaths(nodes);
      final actual = resolveNotebookPaths(nodes);
      _expectPaths(actual, expected);
      expect(notebookPathKey(['📁', 'A']), '2:📁1:A');
      expect(
        notebookPathKey(['📁', 'A']),
        dart_oracle.notebookPathKey(['📁', 'A']),
      );

      const selectedStarts = ['deep', 'orphan', 'cycle-a', 'unknown'];
      expect(
        selectExportNotebookIds(
          noteNotebookIds: selectedStarts,
          notebooks: nodes,
        ),
        dart_oracle.selectExportNotebookIds(
          noteNotebookIds: selectedStarts,
          notebooks: nodes,
        ),
      );
    });
  });

  group('plain-text OT', () {
    test('diffs and applications match Dart across semantic UTF-16 cases', () {
      const cases = [
        (before: '', after: 'hello'),
        (before: 'hello', after: ''),
        (before: 'A😀B', after: 'A😀XB'),
        (before: 'A😀B', after: 'AB'),
        (before: 'alpha beta', after: 'alpha BETA'),
        (before: 'Cafe\u0301 noir', after: 'Cafe\u0301 au lait'),
        (before: 'unchanged', after: 'unchanged'),
      ];

      for (final sample in cases) {
        final expectedDelta = dart_oracle.plainTextDiff(
          sample.before,
          sample.after,
        );
        final actualDelta = plainTextDiff(sample.before, sample.after);
        expect(
          actualDelta,
          expectedDelta,
          reason: '${sample.before} -> ${sample.after}',
        );
        expect(applyPlainTextDelta(sample.before, actualDelta), sample.after);
        expect(
          applyPlainTextDelta(sample.before, expectedDelta),
          dart_oracle.applyPlainTextDelta(sample.before, expectedDelta),
        );
      }
    });

    test('rebasing and selection transforms match Dart with emoji', () {
      const rebaseCases = [
        (oldServer: 'ab', newServer: 'aSb', local: 'aLb'),
        (oldServer: 'A😀B', newServer: 'A😀YB', local: 'A😀XB'),
        (
          oldServer: 'hello world',
          newServer: 'hello brave world',
          local: 'HELLO world',
        ),
        (oldServer: 'same', newServer: 'server', local: 'same'),
      ];
      for (final sample in rebaseCases) {
        expect(
          rebasePlainText(
            oldServer: sample.oldServer,
            newServer: sample.newServer,
            local: sample.local,
          ),
          dart_oracle.rebasePlainText(
            oldServer: sample.oldServer,
            newServer: sample.newServer,
            local: sample.local,
          ),
        );
      }

      const oldServer = 'A😀B';
      const newServer = 'ZA😀YB';
      const local = 'A😀XB';
      final serverChange = dart_oracle.plainTextDiff(oldServer, newServer);
      expect(
        rebasePlainText(
          oldServer: oldServer,
          newServer: newServer,
          local: local,
          serverChange: serverChange,
        ),
        dart_oracle.rebasePlainText(
          oldServer: oldServer,
          newServer: newServer,
          local: local,
          serverChange: serverChange,
        ),
      );

      const positions = [-1, 0, 1, 3, 4, 999];
      final expectedPositions = dart_oracle.transformTextPositions(
        before: oldServer,
        after: newServer,
        positions: positions,
      );
      final actualPositions = transformTextPositions(
        before: oldServer,
        after: newServer,
        positions: positions,
      );
      expect(actualPositions, expectedPositions);
      expect(actualPositions.first, newServer.length);
      expect(
        actualPositions.every(
          (position) => position >= 0 && position <= newServer.length,
        ),
        isTrue,
      );
    });
  });

  group('Markdown and text shaping', () {
    test('Markdown structure parsing matches Dart', () {
      final cases = [
        (
          text: 'intro\r\n# Heading 😀\r\n\r\nbody',
          filename: r'C:\notes\fallback.MD',
        ),
        (text: '#\nBody', filename: '/tmp/empty-heading.md'),
        (
          text: '\uFEFF#\uFEFF Heading\uFEFF\nBody',
          filename: '/tmp/bom-heading.md',
        ),
        (text: 'plain\rtext', filename: 'note.txt'),
      ];
      for (final sample in cases) {
        final actual = parseMarkdownTextCore(sample.text, sample.filename);
        final expected = dart_oracle.parseMarkdownTextCore(
          sample.text,
          sample.filename,
        );
        expect(actual.title, expected.title);
        expect(actual.content, expected.content);
        expect(actual.contentType, expected.contentType);
      }
    });

    test('note rendering and unique export files match Dart', () {
      final notes = <ExportNoteValue>[
        (
          id: 'note-123456',
          title: 'Résumé 😀',
          content: 'First body  \n',
          tagNames: ['work', '😀'],
        ),
        (
          id: 'note-123456',
          title: 'Résumé 😀',
          content: 'Second body',
          tagNames: const [],
        ),
        (
          id: 'short',
          title: 'Untitled',
          content: 'Body only\n\n',
          tagNames: const [],
        ),
      ];

      for (final note in notes) {
        expect(renderNoteMarkdown(note), dart_oracle.renderNoteMarkdown(note));
        expect(renderNoteText(note), dart_oracle.renderNoteText(note));
      }
      const bomNote = (
        id: 'bom-note',
        title: '\uFEFFTitle\uFEFF',
        content: '\uFEFFBody\uFEFF',
        tagNames: <String>['\uFEFFtag\uFEFF'],
      );
      expect(
        renderNoteMarkdown(bomNote),
        dart_oracle.renderNoteMarkdown(bomNote),
      );
      expect(renderNoteText(bomNote), dart_oracle.renderNoteText(bomNote));
      _expectTextFiles(
        renderMarkdownFiles(notes),
        dart_oracle.renderMarkdownFiles(notes),
      );
      _expectTextFiles(
        renderTextFiles(notes),
        dart_oracle.renderTextFiles(notes),
      );
      expect(renderTextFiles(notes).map((file) => file.filename), [
        'rsum--123456.txt',
        'rsum--123456-2.txt',
        'untitled-short.txt',
      ]);
    });
  });
}
