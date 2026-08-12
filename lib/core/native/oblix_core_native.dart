import 'dart:typed_data';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibraryLoaderConfig, loadExternalLibrary;

import 'crdt_types.dart';
import 'generated/api/codecs.dart' as rust_codecs;
import 'generated/api/crdt.dart' as rust;
import 'generated/api/entities.dart' as rust_entities;
import 'generated/api/formats.dart' as rust_formats;
import 'generated/api/mutations.dart' as rust_mutations;
import 'generated/api/ocr.dart' as rust_ocr;
import 'generated/api/pdf.dart' as rust_pdf;
import 'generated/api/policy.dart' as rust_policy;
import 'generated/api/prepare.dart' as rust_prepare;
import 'generated/api/script.dart' as rust_script;
import 'generated/api/quickadd.dart' as rust_quickadd;
import 'generated/api/tasks.dart' as rust_tasks;
import 'generated/api/text.dart' as rust_text;
import 'generated/api/textlayer.dart' as rust_layer;
import 'generated/api/view.dart' as rust_view;
import 'generated/frb_generated.dart';
import 'oblix_core_fallback.dart' as fallback;
import 'task_types.dart';

bool _isInitialized = false;

bool get isRustCoreReady => _isInitialized;

Future<void> initializeOblixCore() async {
  if (_isInitialized) return;
  final library = await loadExternalLibrary(
    const ExternalLibraryLoaderConfig(
      stem: 'oblix_core',
      ioDirectory: 'rust/target/release/',
      webPrefix: 'pkg/',
    ),
  );
  await RustLib.init(externalLibrary: library);
  _isInitialized = true;
}

CoreImportBundleValue parseEnexCore({
  required String xml,
  String? notebookName,
  required int nowMicrosUtc,
}) => _codecCall(
  () => _fromRustImportBundle(
    rust_codecs.parseEnex(
      xml: xml,
      notebookName: notebookName,
      nowMicrosUtc: nowMicrosUtc,
    ),
  ),
);

List<int> exportEpubCore({
  required List<CoreEpubNoteValue> notes,
  required int exportedAtMicrosUtc,
  required String bookUuid,
}) => _codecCall(
  () => List<int>.unmodifiable(
    rust_codecs.exportEpub(
      request: rust_codecs.EpubExportRequestDto(
        notes: [
          for (final note in notes)
            rust_codecs.EpubNoteInputDto(
              title: note.title,
              content: note.content,
            ),
        ],
        exportedAtMicrosUtc: exportedAtMicrosUtc,
        bookUuid: bookUuid,
      ),
    ),
  ),
);

CoreImportBundleValue importEpubCore({
  required List<int> bytes,
  required int nowMicrosUtc,
}) => _codecCall(
  () => _fromRustImportBundle(
    rust_codecs.importEpub(bytes: bytes, nowMicrosUtc: nowMicrosUtc),
  ),
);

List<int> encodeOblixArchiveCore({
  required List<CoreOblixNoteValue> notes,
  required List<CoreOblixNotebookValue> notebooks,
  required List<String> tagNames,
  required List<CoreOblixAttachmentGroupValue> attachmentGroups,
  required int exportedAtMicrosUtc,
}) => _codecCall(
  () => List<int>.unmodifiable(
    rust_codecs.encodeOblixArchive(
      request: rust_codecs.OblixEncodeRequestDto(
        notes: [
          for (final note in notes)
            rust_codecs.OblixNoteInputDto(
              id: note.id,
              notebookId: note.notebookId,
              title: note.title,
              content: note.content,
              contentType: note.contentType,
              tagNames: note.tagNames,
              isPinned: note.isPinned,
              isArchived: note.isArchived,
              createdAtIsoUtc: note.createdAtIsoUtc,
              updatedAtIsoUtc: note.updatedAtIsoUtc,
            ),
        ],
        notebooks: [
          for (final notebook in notebooks)
            rust_codecs.OblixNotebookInputDto(
              id: notebook.id,
              name: notebook.name,
              parentId: notebook.parentId,
              sortOrder: notebook.sortOrder,
            ),
        ],
        tagNames: tagNames,
        attachmentGroups: [
          for (final group in attachmentGroups)
            rust_codecs.OblixAttachmentGroupInputDto(
              noteId: group.noteId,
              attachments: [
                for (final attachment in group.attachments)
                  rust_codecs.OblixAttachmentInputDto(
                    id: attachment.id,
                    originalName: attachment.originalName,
                    mimeType: attachment.mimeType,
                    bytes: Uint8List.fromList(attachment.bytes),
                  ),
              ],
            ),
        ],
        exportedAtMicrosUtc: exportedAtMicrosUtc,
      ),
    ),
  ),
);

CoreImportBundleValue decodeOblixArchiveCore({
  required List<int> bytes,
  required int nowMicrosUtc,
}) => _codecCall(
  () => _fromRustImportBundle(
    rust_codecs.decodeOblixArchive(
      request: rust_codecs.OblixDecodeRequestDto(
        bytes: Uint8List.fromList(bytes),
        nowMicrosUtc: nowMicrosUtc,
      ),
    ),
  ),
);

T _codecCall<T>(T Function() call) {
  if (!_isInitialized) {
    throw StateError('Rust archive codecs require an initialized Oblix core.');
  }
  try {
    return call();
  } on rust_codecs.CodecErrorDto catch (error) {
    throw FormatException(error.message);
  }
}

CoreImportBundleValue _fromRustImportBundle(
  rust_codecs.ImportBundleDto bundle,
) => (
  notes: List<CoreImportedNoteValue>.unmodifiable(
    bundle.notes.map(_fromRustImportedNote),
  ),
  notebookNames: List<String>.unmodifiable(bundle.notebookNames),
  notebookPaths: List.unmodifiable([
    for (final path in bundle.notebookPaths) List<String>.unmodifiable(path),
  ]),
);

CoreImportedNoteValue _fromRustImportedNote(rust_codecs.ImportedNoteDto note) {
  final createdAtMicrosUtc = note.createdAtRaw == null
      ? note.createdAtMicrosUtc
      : DateTime.tryParse(note.createdAtRaw!)?.toUtc().microsecondsSinceEpoch ??
            note.createdAtMicrosUtc;
  final updatedAtMicrosUtc = note.updatedAtRaw == null
      ? note.updatedAtMicrosUtc
      : DateTime.tryParse(note.updatedAtRaw!)?.toUtc().microsecondsSinceEpoch ??
            createdAtMicrosUtc;
  return (
    title: note.title,
    content: note.content,
    contentType: note.contentType,
    tagNames: List<String>.unmodifiable(note.tagNames),
    isPinned: note.isPinned,
    isArchived: note.isArchived,
    createdAtMicrosUtc: createdAtMicrosUtc,
    updatedAtMicrosUtc: updatedAtMicrosUtc,
    notebookName: note.notebookName,
    notebookPath: note.notebookPath == null
        ? null
        : List<String>.unmodifiable(note.notebookPath!),
    attachments: List<CoreImportedAttachmentValue>.unmodifiable(
      note.attachments.map(
        (attachment) => (
          originalName: attachment.originalName,
          mimeType: attachment.mimeType,
          bytes: List<int>.unmodifiable(attachment.bytes),
        ),
      ),
    ),
    skippedAttachments: note.skippedAttachments,
  );
}

Set<String> remoteWinningFields({
  required Iterable<String> fields,
  required Map<String, CrdtClockValue> localClocks,
  required CrdtClockValue localFallback,
  required Map<String, CrdtClockValue> remoteClocks,
  required CrdtClockValue remoteFallback,
  Set<String> excludedFields = const {},
}) {
  if (!_isInitialized) {
    return fallback.remoteWinningFields(
      fields: fields,
      localClocks: localClocks,
      localFallback: localFallback,
      remoteClocks: remoteClocks,
      remoteFallback: remoteFallback,
      excludedFields: excludedFields,
    );
  }

  final inputs = [
    for (final field in fields)
      rust.CrdtFieldInput(
        field: field,
        local: _toRust(localClocks[field] ?? localFallback),
        remote: _toRust(remoteClocks[field] ?? remoteFallback),
        excluded: excludedFields.contains(field),
      ),
  ];
  return Set.unmodifiable(rust.remoteWinningFields(inputs: inputs));
}

rust.CrdtClockInput _toRust(CrdtClockValue clock) => rust.CrdtClockInput(
  timestampMicrosUtc: clock.timestampMicrosUtc,
  deviceId: clock.deviceId,
);

Map<String, CrdtClockValue> stampCrdtClockValues({
  required Map<String, CrdtClockValue> existing,
  required Iterable<String> fields,
  required int timestampMicrosUtc,
  required String deviceId,
}) {
  if (!_isInitialized) {
    return fallback.stampCrdtClockValues(
      existing: existing,
      fields: fields,
      timestampMicrosUtc: timestampMicrosUtc,
      deviceId: deviceId,
    );
  }
  final stamped = rust.stampCrdtFields(
    existing: [
      for (final entry in existing.entries)
        rust.NamedCrdtClockInput(field: entry.key, clock: _toRust(entry.value)),
    ],
    fields: fields.toList(growable: false),
    timestampMicrosUtc: timestampMicrosUtc,
    deviceId: deviceId,
  );
  return Map.unmodifiable({
    for (final entry in stamped)
      entry.field: (
        timestampMicrosUtc: entry.clock.timestampMicrosUtc,
        deviceId: entry.clock.deviceId,
      ),
  });
}

int nextLogicalTimestampMicros({
  required int nowMicrosUtc,
  int? previousMicrosUtc,
}) => _isInitialized
    ? rust_policy.nextLogicalTimestampMicros(
        nowMicrosUtc: nowMicrosUtc,
        previousMicrosUtc: previousMicrosUtc,
      )
    : fallback.nextLogicalTimestampMicros(
        nowMicrosUtc: nowMicrosUtc,
        previousMicrosUtc: previousMicrosUtc,
      );

bool collaborationTokenNeedsRefresh(String token, {required int nowSeconds}) =>
    _isInitialized
    ? rust_policy.tokenNeedsRefresh(token: token, nowEpochSeconds: nowSeconds)
    : fallback.collaborationTokenNeedsRefresh(token, nowSeconds: nowSeconds);

String? jwtSubject(String token) => _isInitialized
    ? rust_policy.jwtSubject(token: token)
    : fallback.jwtSubject(token);

bool collaborationSnapshotIsStale({
  String? lastEpoch,
  int? lastRevision,
  required String incomingEpoch,
  required int incomingRevision,
}) => _isInitialized
    ? rust_policy.collaborationSnapshotIsStale(
        lastEpoch: lastEpoch,
        lastRevision: lastRevision,
        incomingEpoch: incomingEpoch,
        incomingRevision: incomingRevision,
      )
    : fallback.collaborationSnapshotIsStale(
        lastEpoch: lastEpoch,
        lastRevision: lastRevision,
        incomingEpoch: incomingEpoch,
        incomingRevision: incomingRevision,
      );

String normalizeTaskTitle(String title) => _isInitialized
    ? rust_policy.normalizeTaskTitle(title: title)
    : fallback.normalizeTaskTitle(title);

String normalizeNoteTitle(String title) => _isInitialized
    ? rust_policy.normalizeNoteTitle(title: title)
    : fallback.normalizeNoteTitle(title);

bool noteDraftIsEmpty({required String title, required String content}) =>
    _isInitialized
    ? rust_policy.noteDraftIsEmpty(title: title, content: content)
    : fallback.noteDraftIsEmpty(title: title, content: content);

String noteShareText({required String title, required String content}) =>
    _isInitialized
    ? rust_policy.noteShareText(title: title, content: content)
    : fallback.noteShareText(title: title, content: content);

List<String> parseTagNames(String raw) => _isInitialized
    ? List.unmodifiable(rust_policy.parseTagNames(raw: raw))
    : fallback.parseTagNames(raw);

String sanitizeSingleExportStem(String title) => _isInitialized
    ? rust_policy.sanitizeSingleExportStem(title: title)
    : fallback.sanitizeSingleExportStem(title);

int clampImportedTimestampMicros({
  required int timestampMicrosUtc,
  required int nowMicrosUtc,
}) => _isInitialized
    ? rust_policy.clampImportedTimestampMicros(
        timestampMicrosUtc: timestampMicrosUtc,
        nowMicrosUtc: nowMicrosUtc,
      )
    : fallback.clampImportedTimestampMicros(
        timestampMicrosUtc: timestampMicrosUtc,
        nowMicrosUtc: nowMicrosUtc,
      );

bool remoteTimestampWinsEqual({
  required int localTimestampMicrosUtc,
  required int remoteTimestampMicrosUtc,
}) => _isInitialized
    ? rust_policy.remoteTimestampWinsEqual(
        localTimestampMicrosUtc: localTimestampMicrosUtc,
        remoteTimestampMicrosUtc: remoteTimestampMicrosUtc,
      )
    : fallback.remoteTimestampWinsEqual(
        localTimestampMicrosUtc: localTimestampMicrosUtc,
        remoteTimestampMicrosUtc: remoteTimestampMicrosUtc,
      );

int syncBackoffMillis({
  required int consecutiveFailures,
  required int baseMillis,
  required int maxMillis,
}) => _isInitialized
    ? rust_policy.syncBackoffMillis(
        consecutiveFailures: consecutiveFailures,
        baseMillis: baseMillis,
        maxMillis: maxMillis,
      )
    : fallback.syncBackoffMillis(
        consecutiveFailures: consecutiveFailures,
        baseMillis: baseMillis,
        maxMillis: maxMillis,
      );

PendingOutboxSummaryValue summarizePendingOutbox(
  List<PendingOutboxRowValue> rows,
) {
  if (!_isInitialized) return fallback.summarizePendingOutbox(rows);
  final summary = rust_policy.summarizePendingOutbox(
    rows: [
      for (final row in rows)
        rust_policy.PendingOutboxRowInput(
          seq: row.seq,
          action: row.action,
          dataJson: row.dataJson,
        ),
    ],
  );
  return (
    fields: Set.unmodifiable(summary.fields),
    updateSeqsByField: Map.unmodifiable({
      for (final entry in summary.updateSeqsByField)
        entry.field: Set<int>.unmodifiable(
          entry.seqs.map((sequence) => sequence.toInt()),
        ),
    }),
  );
}

OutboxRetirementValue retireAcknowledgedOutboxField({
  required String dataJson,
  required String field,
}) {
  if (!_isInitialized) {
    return fallback.retireAcknowledgedOutboxField(
      dataJson: dataJson,
      field: field,
    );
  }
  final result = rust_policy.retireAcknowledgedOutboxField(
    dataJson: dataJson,
    field: field,
  );
  return (
    changed: result.changed,
    deleteRow: result.deleteRow,
    dataJson: result.dataJson,
  );
}

List<int> eligibleSyncSequences({
  required List<SyncBatchEntryValue> entries,
  required Set<String> protectedNoteIds,
}) {
  if (!_isInitialized) {
    return fallback.eligibleSyncSequences(
      entries: entries,
      protectedNoteIds: protectedNoteIds,
    );
  }
  return List.unmodifiable(
    rust_policy
        .eligibleSyncSequences(
          entries: _toRustSyncEntries(entries),
          protectedNoteIds: protectedNoteIds.toList(growable: false),
        )
        .map((sequence) => sequence.toInt()),
  );
}

SyncSettlementValue planSyncSettlement({
  required List<SyncBatchEntryValue> entries,
  required Set<String> decidedEntityIds,
  required bool protectedServerNoteSeen,
  required int batchSize,
  required List<int> pulledEntityCounts,
  required int droppedCount,
}) {
  if (!_isInitialized) {
    return fallback.planSyncSettlement(
      entries: entries,
      decidedEntityIds: decidedEntityIds,
      protectedServerNoteSeen: protectedServerNoteSeen,
      batchSize: batchSize,
      pulledEntityCounts: pulledEntityCounts,
      droppedCount: droppedCount,
    );
  }
  final plan = rust_policy.planSyncSettlement(
    entries: _toRustSyncEntries(entries),
    decidedEntityIds: decidedEntityIds.toList(growable: false),
    protectedServerNoteSeen: protectedServerNoteSeen,
    batchSize: batchSize,
    pulledEntityCounts: pulledEntityCounts,
    droppedCount: droppedCount,
  );
  return (
    ackedSeqs: List.unmodifiable(
      plan.ackedSeqs.map((sequence) => sequence.toInt()),
    ),
    retrySeqs: List.unmodifiable(
      plan.retrySeqs.map((sequence) => sequence.toInt()),
    ),
    pulledCount: plan.pulledCount,
    anythingChanged: plan.anythingChanged,
    continueDraining: plan.continueDraining,
  );
}

List<rust_policy.SyncBatchEntryInput> _toRustSyncEntries(
  List<SyncBatchEntryValue> entries,
) => [
  for (final entry in entries)
    rust_policy.SyncBatchEntryInput(
      seq: entry.seq,
      entityType: entry.entityType,
      entityId: entry.entityId,
    ),
];

List<NotebookPathValue> resolveNotebookPaths(List<NotebookNodeValue> nodes) {
  if (!_isInitialized) return fallback.resolveNotebookPaths(nodes);
  return List.unmodifiable(
    rust_policy
        .resolveNotebookPaths(nodes: _toRustNotebookNodes(nodes))
        .map(
          (path) => (
            id: path.id,
            path: List<String>.unmodifiable(path.path),
            pathKey: path.pathKey,
          ),
        ),
  );
}

List<String> selectExportNotebookIds({
  required Iterable<String> noteNotebookIds,
  required List<NotebookNodeValue> notebooks,
}) => _isInitialized
    ? List.unmodifiable(
        rust_policy.selectExportNotebookIds(
          noteNotebookIds: noteNotebookIds.toList(growable: false),
          nodes: _toRustNotebookNodes(notebooks),
        ),
      )
    : fallback.selectExportNotebookIds(
        noteNotebookIds: noteNotebookIds,
        notebooks: notebooks,
      );

String notebookPathKey(List<String> path) => _isInitialized
    ? rust_policy.notebookPathKey(path: path)
    : fallback.notebookPathKey(path);

List<rust_policy.NotebookNodeInput> _toRustNotebookNodes(
  List<NotebookNodeValue> nodes,
) => [
  for (final node in nodes)
    rust_policy.NotebookNodeInput(
      id: node.id,
      name: node.name,
      parentId: node.parentId,
    ),
];

List<Map<String, dynamic>> plainTextDiff(String before, String after) {
  if (!_isInitialized) return fallback.plainTextDiff(before, after);
  return List.unmodifiable(
    rust_text.plainTextDiff(before: before, after: after).map(_deltaToJson),
  );
}

String applyPlainTextDelta(String text, List<dynamic> delta) {
  if (!_isInitialized) return fallback.applyPlainTextDelta(text, delta);
  final result = rust_text.applyPlainTextDelta(
    text: text,
    operations: _deltaFromJson(delta),
  );
  return _unwrapTextResult(result);
}

List<int> transformTextPositions({
  required String before,
  required String after,
  required List<int> positions,
}) => _isInitialized
    ? List.unmodifiable(
        rust_text.transformTextPositions(
          before: before,
          after: after,
          positions: positions,
        ),
      )
    : fallback.transformTextPositions(
        before: before,
        after: after,
        positions: positions,
      );

String rebasePlainText({
  required String oldServer,
  required String newServer,
  required String local,
  List<dynamic>? serverChange,
}) {
  if (!_isInitialized) {
    return fallback.rebasePlainText(
      oldServer: oldServer,
      newServer: newServer,
      local: local,
      serverChange: serverChange,
    );
  }
  final result = rust_text.rebasePlainText(
    oldServer: oldServer,
    newServer: newServer,
    local: local,
    serverChange: serverChange == null ? null : _deltaFromJson(serverChange),
  );
  return _unwrapTextResult(result);
}

List<rust_text.TextDeltaOp> _deltaFromJson(List<dynamic> delta) => [
  for (final raw in delta)
    _deltaOperationFromJson(Map<String, dynamic>.from(raw as Map)),
];

rust_text.TextDeltaOp _deltaOperationFromJson(
  Map<String, dynamic> operation,
) => rust_text.TextDeltaOp(
  retain: operation.containsKey('retain') ? operation['retain'] as int : null,
  delete: operation.containsKey('delete') ? operation['delete'] as int : null,
  insert: operation.containsKey('insert')
      ? operation['insert'] as String
      : null,
);

Map<String, dynamic> _deltaToJson(rust_text.TextDeltaOp operation) => {
  if (operation.retain != null) 'retain': operation.retain,
  if (operation.delete != null) 'delete': operation.delete,
  if (operation.insert != null) 'insert': operation.insert,
};

String _unwrapTextResult(rust_text.TextOperationResult result) {
  if (result.error case final error?) throw FormatException(error);
  return result.value;
}

String noteSnippet(String content) => _isInitialized
    ? rust_view.noteSnippet(content: content)
    : fallback.noteSnippet(content);

ScannedNoteDraftValue shapeScannedText({
  required List<OcrLineValue> lines,
  double minConfidence = 0,
  bool preserveLineBreaks = false,
  bool detectColumns = true,
  bool detectStructure = true,
  bool detectTables = true,
  bool stripRunningHeads = true,
  bool healAcrossPages = true,
  ScanPresetValue preset = ScanPresetValue.auto,
}) => shapeScannedPages(
  pages: [(lines: lines, width: 0, height: 0)],
  minConfidence: minConfidence,
  preserveLineBreaks: preserveLineBreaks,
  detectColumns: detectColumns,
  detectStructure: detectStructure,
  detectTables: detectTables,
  stripRunningHeads: stripRunningHeads,
  healAcrossPages: healAcrossPages,
  preset: preset,
);

ScannedNoteDraftValue shapeScannedPages({
  required List<OcrPageValue> pages,
  double minConfidence = 0,
  bool preserveLineBreaks = false,
  bool detectColumns = true,
  bool detectStructure = true,
  bool detectTables = true,
  bool stripRunningHeads = true,
  bool healAcrossPages = true,
  ScanPresetValue preset = ScanPresetValue.auto,
}) {
  if (!_isInitialized) {
    return fallback.shapeScannedPages(
      pages: pages,
      minConfidence: minConfidence,
      preserveLineBreaks: preserveLineBreaks,
      detectColumns: detectColumns,
      detectStructure: detectStructure,
      detectTables: detectTables,
      stripRunningHeads: stripRunningHeads,
      healAcrossPages: healAcrossPages,
      preset: preset,
    );
  }
  final draft = rust_ocr.shapeScannedPages(
    pages: [for (final page in pages) _toRustPage(page)],
    options: rust_ocr.OcrShapeOptions(
      minConfidence: minConfidence,
      preserveLineBreaks: preserveLineBreaks,
      detectColumns: detectColumns,
      detectStructure: detectStructure,
      detectTables: detectTables,
      stripRunningHeads: stripRunningHeads,
      healAcrossPages: healAcrossPages,
      preset: rust_ocr.ScanPreset.values[preset.index],
    ),
  );
  return (
    title: draft.title,
    body: draft.body,
    contentType: draft.contentType,
    keptLines: draft.keptLines,
    droppedLines: draft.droppedLines,
    columns: draft.columns,
    correctedSkewDegrees: draft.correctedSkewDegrees,
    pages: draft.pages,
    tables: draft.tables,
    headings: draft.headings,
    strippedRunningHeads: draft.strippedRunningHeads,
    preset: draft.preset,
    quality: (
      verdict: QualityVerdictValue.values[draft.quality.verdict.index],
      meanConfidence: draft.quality.meanConfidence,
      lowConfidenceShare: draft.quality.lowConfidenceShare,
      scoredLines: draft.quality.scoredLines,
      advice: draft.quality.advice,
    ),
  );
}

List<rust_ocr.OcrLineInput> _toRustLines(List<OcrLineValue> lines) => [
  for (final line in lines)
    rust_ocr.OcrLineInput(
      text: line.text,
      left: line.left,
      top: line.top,
      right: line.right,
      bottom: line.bottom,
      blockIndex: line.blockIndex,
      confidence: line.confidence,
    ),
];

OcrLineValue _fromRustLine(rust_ocr.OcrLineInput line) => (
  text: line.text,
  left: line.left,
  top: line.top,
  right: line.right,
  bottom: line.bottom,
  blockIndex: line.blockIndex,
  confidence: line.confidence,
);

rust_ocr.OcrPageInput _toRustPage(OcrPageValue page) => rust_ocr.OcrPageInput(
  width: page.width,
  height: page.height,
  lines: _toRustLines(page.lines),
);

OcrPageValue _fromRustPage(rust_ocr.OcrPageInput page) => (
  width: page.width,
  height: page.height,
  lines: [for (final line in page.lines) _fromRustLine(line)],
);

// --- Text layers ---

rust_layer.TextLayer _toRustLayer(TextLayerValue layer) => rust_layer.TextLayer(
  source: layer.source,
  pages: [
    for (final page in layer.pages)
      rust_layer.TextLayerPage(
        width: page.width,
        height: page.height,
        lines: [
          for (final line in page.lines)
            rust_layer.TextLayerLine(
              text: line.text,
              left: line.left,
              top: line.top,
              right: line.right,
              bottom: line.bottom,
              confidence: line.confidence,
            ),
        ],
      ),
  ],
);

TextLayerValue _fromRustLayer(rust_layer.TextLayer layer) => (
  source: layer.source,
  pages: [
    for (final page in layer.pages)
      (
        width: page.width,
        height: page.height,
        lines: [
          for (final line in page.lines)
            (
              text: line.text,
              left: line.left,
              top: line.top,
              right: line.right,
              bottom: line.bottom,
              confidence: line.confidence,
            ),
        ],
      ),
  ],
);

TextLayerValue buildTextLayer({
  required List<OcrPageValue> pages,
  required String source,
}) => _isInitialized
    ? _fromRustLayer(
        rust_layer.buildTextLayer(
          pages: [for (final page in pages) _toRustPage(page)],
          source: source,
        ),
      )
    : fallback.buildTextLayer(pages: pages, source: source);

List<OcrPageValue> textLayerToPages(TextLayerValue layer) => _isInitialized
    ? [
        for (final page in rust_layer.textLayerToPages(
          layer: _toRustLayer(layer),
        ))
          _fromRustPage(page),
      ]
    : fallback.textLayerToPages(layer);

String encodeTextLayer(TextLayerValue layer) => _isInitialized
    ? rust_layer.encodeTextLayer(layer: _toRustLayer(layer))
    : fallback.encodeTextLayer(layer);

/// Throws [FormatException] when the blob is not a readable text layer, so a
/// corrupt or future-versioned sidecar degrades to "no text layer" rather than
/// taking the note with it.
TextLayerValue decodeTextLayer(String encoded) {
  if (!_isInitialized) return fallback.decodeTextLayer(encoded);
  try {
    return _fromRustLayer(rust_layer.decodeTextLayer(encoded: encoded));
  } on rust_layer.TextLayerError catch (error) {
    throw FormatException(error.message);
  }
}

String textLayerSearchText(TextLayerValue layer) => _isInitialized
    ? rust_layer.textLayerSearchText(layer: _toRustLayer(layer))
    : fallback.textLayerSearchText(layer);

List<TextLayerHitValue> findInTextLayer({
  required TextLayerValue layer,
  required String query,
}) => _isInitialized
    ? [
        for (final hit in rust_layer.findInTextLayer(
          layer: _toRustLayer(layer),
          query: query,
        ))
          (
            page: hit.page,
            line: hit.line,
            text: hit.text,
            left: hit.left,
            top: hit.top,
            right: hit.right,
            bottom: hit.bottom,
          ),
      ]
    : fallback.findInTextLayer(layer: layer, query: query);

String textLayerRegion({
  required TextLayerValue layer,
  required int page,
  required double left,
  required double top,
  required double right,
  required double bottom,
}) => _isInitialized
    ? rust_layer.textLayerRegion(
        layer: _toRustLayer(layer),
        page: page,
        left: left,
        top: top,
        right: right,
        bottom: bottom,
      )
    : fallback.textLayerRegion(
        layer: layer,
        page: page,
        left: left,
        top: top,
        right: right,
        bottom: bottom,
      );

String textLayerFingerprint(TextLayerValue layer) => _isInitialized
    ? rust_layer.textLayerFingerprint(layer: _toRustLayer(layer))
    : fallback.textLayerFingerprint(layer);

int fingerprintDistance(String left, String right) => _isInitialized
    ? rust_layer.fingerprintDistance(left: left, right: right)
    : fallback.fingerprintDistance(left, right);

bool textLayerLooksDuplicate(String left, String right) => _isInitialized
    ? rust_layer.textLayerLooksDuplicate(left: left, right: right)
    : fallback.textLayerLooksDuplicate(left, right);

// --- Entities, redaction and actions ---

List<EntityValue> extractEntities({
  required String text,
  bool dayFirst = true,
}) => _isInitialized
    ? [
        for (final entity in rust_entities.extractEntities(
          text: text,
          options: rust_entities.EntityOptions(dayFirst: dayFirst),
        ))
          (
            kind: EntityKindValue.values[entity.kind.index],
            text: entity.text,
            start: entity.start,
            end: entity.end,
            normalized: entity.normalized,
            currency: entity.currency,
          ),
      ]
    : fallback.extractEntities(text: text, dayFirst: dayFirst);

List<RedactionSpanValue> findRedactions({
  required TextLayerValue layer,
  List<EntityKindValue> kinds = const [],
  bool dayFirst = true,
}) => _isInitialized
    ? [
        for (final span in rust_entities.findRedactions(
          layer: _toRustLayer(layer),
          kinds: [
            for (final kind in kinds) rust_entities.EntityKind.values[kind.index],
          ],
          options: rust_entities.EntityOptions(dayFirst: dayFirst),
        ))
          (
            kind: EntityKindValue.values[span.kind.index],
            page: span.page,
            left: span.left,
            top: span.top,
            right: span.right,
            bottom: span.bottom,
            label: span.label,
          ),
      ]
    : fallback.findRedactions(layer: layer, kinds: kinds, dayFirst: dayFirst);

List<SuggestedActionValue> suggestActions({
  required String text,
  bool dayFirst = true,
}) => _isInitialized
    ? [
        for (final action in rust_entities.suggestActions(
          text: text,
          options: rust_entities.EntityOptions(dayFirst: dayFirst),
        ))
          (
            kind: ActionKindValue.values[action.kind.index],
            title: action.title,
            detail: action.detail,
            year: action.year,
            month: action.month,
            day: action.day,
            hour: action.hour,
            minute: action.minute,
            amountMinor: action.amountMinor,
            currency: action.currency,
          ),
      ]
    : fallback.suggestActions(text: text, dayFirst: dayFirst);

// --- PDF ---

rust_pdf.PdfPageInput _toRustPdfPage(PdfPageValue page) => rust_pdf.PdfPageInput(
  width: page.width,
  height: page.height,
  hasImage: page.hasImage,
  runs: [
    for (final run in page.runs)
      rust_pdf.PdfTextRun(
        text: run.text,
        x: run.x,
        y: run.y,
        width: run.width,
        height: run.height,
      ),
  ],
);

PdfPageAssessmentValue assessPdfPage(PdfPageValue page) {
  if (!_isInitialized) return fallback.assessPdfPage(page);
  final assessment = rust_pdf.assessPdfPage(page: _toRustPdfPage(page));
  return (
    plan: PdfPagePlanValue.values[assessment.plan.index],
    reason: assessment.reason,
    coverage: assessment.coverage,
    characters: assessment.characters,
    runs: assessment.runs,
  );
}

List<OcrPageValue> pdfPagesToOcrPages({
  required List<PdfPageValue> pages,
  double scale = 1,
}) => _isInitialized
    ? [
        for (final page in rust_pdf.pdfPagesToOcrPages(
          pages: [for (final page in pages) _toRustPdfPage(page)],
          scale: scale,
        ))
          _fromRustPage(page),
      ]
    : fallback.pdfPagesToOcrPages(pages: pages, scale: scale);

List<NoteDayGroupValue> groupNotesByDay({
  required List<NoteDayValue> notes,
  required int todayYear,
  required int todayMonth,
  required int todayDay,
}) {
  if (!_isInitialized) {
    return fallback.groupNotesByDay(
      notes: notes,
      todayYear: todayYear,
      todayMonth: todayMonth,
      todayDay: todayDay,
    );
  }
  return List.unmodifiable(
    rust_view
        .groupNotesByDay(
          notes: [
            for (final note in notes)
              rust_view.NoteDayInput(
                id: note.id,
                localYear: note.localYear,
                localMonth: note.localMonth,
                localDay: note.localDay,
              ),
          ],
          todayYear: todayYear,
          todayMonth: todayMonth,
          todayDay: todayDay,
        )
        .map(
          (group) => (
            label: group.label,
            noteIds: List<String>.unmodifiable(group.noteIds),
          ),
        ),
  );
}

MarkdownImportValue parseMarkdownTextCore(String text, String filename) {
  if (!_isInitialized) return fallback.parseMarkdownTextCore(text, filename);
  final parsed = rust_formats.parseMarkdownText(text: text, filename: filename);
  return (
    title: parsed.title ?? _filenameStem(filename),
    content: parsed.content,
    contentType: parsed.contentType,
  );
}

String renderNoteMarkdown(ExportNoteValue note) => _isInitialized
    ? rust_formats.noteToMarkdown(note: _toRustExportNote(note))
    : fallback.renderNoteMarkdown(note);

String renderNoteText(ExportNoteValue note) => _isInitialized
    ? rust_formats.noteToText(note: _toRustExportNote(note))
    : fallback.renderNoteText(note);

List<ExportTextFileValue> renderMarkdownFiles(List<ExportNoteValue> notes) =>
    _isInitialized
    ? _fromRustFiles(
        rust_formats.renderMarkdownFiles(
          notes: notes.map(_toRustExportNote).toList(growable: false),
        ),
      )
    : fallback.renderMarkdownFiles(notes);

List<ExportTextFileValue> renderTextFiles(List<ExportNoteValue> notes) =>
    _isInitialized
    ? _fromRustFiles(
        rust_formats.renderTextFiles(
          notes: notes.map(_toRustExportNote).toList(growable: false),
        ),
      )
    : fallback.renderTextFiles(notes);

rust_formats.ExportNoteInput _toRustExportNote(ExportNoteValue note) =>
    rust_formats.ExportNoteInput(
      id: note.id,
      title: note.title,
      content: note.content,
      tagNames: note.tagNames,
    );

List<ExportTextFileValue> _fromRustFiles(
  List<rust_formats.ExportTextFileOutput> files,
) => List.unmodifiable([
  for (final file in files) (filename: file.filename, content: file.content),
]);

NoteMutationPlanValue planNoteCreate({
  required String title,
  required String content,
  required String contentType,
  String? notebookId,
  bool isPinned = false,
  bool isArchived = false,
  List<String> tagNames = const [],
}) {
  if (!_isInitialized) {
    return fallback.planNoteCreate(
      title: title,
      content: content,
      contentType: contentType,
      notebookId: notebookId,
      isPinned: isPinned,
      isArchived: isArchived,
      tagNames: tagNames,
    );
  }
  return _fromRustNotePlan(
    rust_mutations.planNoteCreate(
      input: rust_mutations.NoteCreateInput(
        title: title,
        content: content,
        contentType: contentType,
        notebookId: notebookId,
        isPinned: isPinned,
        isArchived: isArchived,
        tagNames: tagNames,
      ),
    ),
  );
}

NoteMutationPlanValue planNoteUpdate({
  required NoteMutationStateValue current,
  String? title,
  String? content,
  String? contentType,
  bool notebookIdProvided = false,
  String? notebookId,
  bool? isPinned,
  bool? isArchived,
  List<String>? tagNames,
}) {
  if (!_isInitialized) {
    return fallback.planNoteUpdate(
      current: current,
      title: title,
      content: content,
      contentType: contentType,
      notebookIdProvided: notebookIdProvided,
      notebookId: notebookId,
      isPinned: isPinned,
      isArchived: isArchived,
      tagNames: tagNames,
    );
  }
  return _fromRustNotePlan(
    rust_mutations.planNoteUpdate(
      current: _toRustNoteState(current),
      update: rust_mutations.NoteUpdateInput(
        title: title,
        content: content,
        contentType: contentType,
        notebookId: rust_mutations.NullableStringMutation(
          provided: notebookIdProvided,
          value: notebookId,
        ),
        isPinned: isPinned,
        isArchived: isArchived,
        tagNames: tagNames,
      ),
    ),
  );
}

NoteMutationPlanValue planNoteDelete(NoteMutationStateValue current) =>
    _isInitialized
    ? _fromRustNotePlan(
        rust_mutations.planNoteDelete(current: _toRustNoteState(current)),
      )
    : fallback.planNoteDelete(current);

NoteMutationPlanValue planNoteRestore(NoteMutationStateValue current) =>
    _isInitialized
    ? _fromRustNotePlan(
        rust_mutations.planNoteRestore(current: _toRustNoteState(current)),
      )
    : fallback.planNoteRestore(current);

NotebookMutationPlanValue planNotebookCreate({
  required String name,
  String? parentId,
  int sortOrder = 0,
}) {
  if (!_isInitialized) {
    return fallback.planNotebookCreate(
      name: name,
      parentId: parentId,
      sortOrder: sortOrder,
    );
  }
  return _fromRustNotebookPlan(
    rust_mutations.planNotebookCreate(
      input: rust_mutations.NotebookCreateInput(
        name: name,
        parentId: parentId,
        sortOrder: sortOrder,
      ),
    ),
  );
}

NotebookMutationPlanValue planNotebookUpdate({
  required NotebookMutationStateValue current,
  String? name,
  bool parentIdProvided = false,
  String? parentId,
  int? sortOrder,
}) {
  if (!_isInitialized) {
    return fallback.planNotebookUpdate(
      current: current,
      name: name,
      parentIdProvided: parentIdProvided,
      parentId: parentId,
      sortOrder: sortOrder,
    );
  }
  return _fromRustNotebookPlan(
    rust_mutations.planNotebookUpdate(
      current: _toRustNotebookState(current),
      update: rust_mutations.NotebookUpdateInput(
        name: name,
        parentId: rust_mutations.NullableStringMutation(
          provided: parentIdProvided,
          value: parentId,
        ),
        sortOrder: sortOrder,
      ),
    ),
  );
}

NotebookMutationPlanValue planNotebookDelete(
  NotebookMutationStateValue current,
) => _isInitialized
    ? _fromRustNotebookPlan(
        rust_mutations.planNotebookDelete(
          current: _toRustNotebookState(current),
        ),
      )
    : fallback.planNotebookDelete(current);

TaskMutationPlanValue planTaskCreate({
  required String title,
  required String description,
  String? noteId,
  String? notebookId,
  String? parentId,
  int? dueDateMicrosUtc,
  bool dueHasTime = false,
  int priority = 0,
  List<String> labels = const [],
  String? recurrence,
  int? reminderAtMicrosUtc,
  int? reminderLeadMinutes,
  int sortOrder = 0,
}) {
  if (!_isInitialized) {
    return fallback.planTaskCreate(
      title: title,
      description: description,
      noteId: noteId,
      notebookId: notebookId,
      parentId: parentId,
      dueDateMicrosUtc: dueDateMicrosUtc,
      dueHasTime: dueHasTime,
      priority: priority,
      labels: labels,
      recurrence: recurrence,
      reminderAtMicrosUtc: reminderAtMicrosUtc,
      reminderLeadMinutes: reminderLeadMinutes,
      sortOrder: sortOrder,
    );
  }
  return _fromRustTaskPlan(
    rust_mutations.planTaskCreate(
      input: rust_mutations.TaskCreateInput(
        title: title,
        description: description,
        noteId: noteId,
        notebookId: notebookId,
        parentId: parentId,
        dueDateMicrosUtc: dueDateMicrosUtc,
        dueHasTime: dueHasTime,
        priority: priority,
        labels: labels,
        recurrence: recurrence,
        reminderAtMicrosUtc: reminderAtMicrosUtc,
        reminderLeadMinutes: reminderLeadMinutes,
        sortOrder: sortOrder,
      ),
    ),
  );
}

TaskMutationPlanValue planTaskUpdate({
  required TaskMutationStateValue current,
  String? title,
  String? description,
  bool noteIdProvided = false,
  String? noteId,
  bool notebookIdProvided = false,
  String? notebookId,
  bool parentIdProvided = false,
  String? parentId,
  bool dueDateProvided = false,
  int? dueDateMicrosUtc,
  bool? dueHasTime,
  int? priority,
  List<String>? labels,
  bool recurrenceProvided = false,
  String? recurrence,
  bool reminderAtProvided = false,
  int? reminderAtMicrosUtc,
  bool reminderLeadProvided = false,
  int? reminderLeadMinutes,
  int? sortOrder,
}) {
  if (!_isInitialized) {
    return fallback.planTaskUpdate(
      current: current,
      title: title,
      description: description,
      noteIdProvided: noteIdProvided,
      noteId: noteId,
      notebookIdProvided: notebookIdProvided,
      notebookId: notebookId,
      parentIdProvided: parentIdProvided,
      parentId: parentId,
      dueDateProvided: dueDateProvided,
      dueDateMicrosUtc: dueDateMicrosUtc,
      dueHasTime: dueHasTime,
      priority: priority,
      labels: labels,
      recurrenceProvided: recurrenceProvided,
      recurrence: recurrence,
      reminderAtProvided: reminderAtProvided,
      reminderAtMicrosUtc: reminderAtMicrosUtc,
      reminderLeadProvided: reminderLeadProvided,
      reminderLeadMinutes: reminderLeadMinutes,
      sortOrder: sortOrder,
    );
  }
  return _fromRustTaskPlan(
    rust_mutations.planTaskUpdate(
      current: _toRustTaskState(current),
      update: rust_mutations.TaskUpdateInput(
        title: title,
        description: description,
        noteId: rust_mutations.NullableStringMutation(
          provided: noteIdProvided,
          value: noteId,
        ),
        notebookId: rust_mutations.NullableStringMutation(
          provided: notebookIdProvided,
          value: notebookId,
        ),
        parentId: rust_mutations.NullableStringMutation(
          provided: parentIdProvided,
          value: parentId,
        ),
        dueDate: rust_mutations.NullableTimestampMutation(
          provided: dueDateProvided,
          valueMicrosUtc: dueDateMicrosUtc,
        ),
        dueHasTime: dueHasTime,
        priority: priority,
        labels: labels,
        recurrence: rust_mutations.NullableStringMutation(
          provided: recurrenceProvided,
          value: recurrence,
        ),
        reminderAt: rust_mutations.NullableTimestampMutation(
          provided: reminderAtProvided,
          valueMicrosUtc: reminderAtMicrosUtc,
        ),
        reminderLeadMinutes: rust_mutations.NullableIntMutation(
          provided: reminderLeadProvided,
          value: reminderLeadMinutes,
        ),
        sortOrder: sortOrder,
      ),
    ),
  );
}

/// Move a repeating task onto its next occurrence instead of retiring it.
/// The caller has already resolved the civil dates into instants.
TaskMutationPlanValue planTaskRollover({
  required TaskMutationStateValue current,
  int? nextDueMicrosUtc,
  int? nextReminderMicrosUtc,
}) => _isInitialized
    ? _fromRustTaskPlan(
        rust_mutations.planTaskRollover(
          current: _toRustTaskState(current),
          nextDueMicrosUtc: nextDueMicrosUtc,
          nextReminderMicrosUtc: nextReminderMicrosUtc,
        ),
      )
    : fallback.planTaskRollover(
        current: current,
        nextDueMicrosUtc: nextDueMicrosUtc,
        nextReminderMicrosUtc: nextReminderMicrosUtc,
      );

TaskMutationPlanValue planTaskCompletion({
  required TaskMutationStateValue current,
  required bool completed,
  required int timestampMicrosUtc,
}) => _isInitialized
    ? _fromRustTaskPlan(
        rust_mutations.planTaskCompletion(
          current: _toRustTaskState(current),
          completed: completed,
          timestampMicrosUtc: timestampMicrosUtc,
        ),
      )
    : fallback.planTaskCompletion(
        current: current,
        completed: completed,
        timestampMicrosUtc: timestampMicrosUtc,
      );

TaskMutationPlanValue planTaskDelete(TaskMutationStateValue current) =>
    _isInitialized
    ? _fromRustTaskPlan(
        rust_mutations.planTaskDelete(current: _toRustTaskState(current)),
      )
    : fallback.planTaskDelete(current);

rust_mutations.NoteMutationState _toRustNoteState(
  NoteMutationStateValue value,
) => rust_mutations.NoteMutationState(
  title: value.title,
  content: value.content,
  contentType: value.contentType,
  notebookId: value.notebookId,
  isPinned: value.isPinned,
  isArchived: value.isArchived,
  isDeleted: value.isDeleted,
  tagNames: value.tagNames,
);

rust_mutations.NotebookMutationState _toRustNotebookState(
  NotebookMutationStateValue value,
) => rust_mutations.NotebookMutationState(
  name: value.name,
  parentId: value.parentId,
  sortOrder: value.sortOrder,
  isDeleted: value.isDeleted,
);

rust_mutations.TaskMutationState _toRustTaskState(
  TaskMutationStateValue value,
) => rust_mutations.TaskMutationState(
  title: value.title,
  description: value.description,
  noteId: value.noteId,
  notebookId: value.notebookId,
  parentId: value.parentId,
  dueDateMicrosUtc: value.dueDateMicrosUtc,
  dueHasTime: value.dueHasTime,
  priority: value.priority,
  labels: value.labels,
  recurrence: value.recurrence,
  reminderAtMicrosUtc: value.reminderAtMicrosUtc,
  reminderLeadMinutes: value.reminderLeadMinutes,
  sortOrder: value.sortOrder,
  isCompleted: value.isCompleted,
  completedAtMicrosUtc: value.completedAtMicrosUtc,
  isDeleted: value.isDeleted,
);

NoteMutationPlanValue _fromRustNotePlan(rust_mutations.NoteMutationPlan plan) =>
    (
      value: (
        title: plan.value.title,
        content: plan.value.content,
        contentType: plan.value.contentType,
        notebookId: plan.value.notebookId,
        isPinned: plan.value.isPinned,
        isArchived: plan.value.isArchived,
        isDeleted: plan.value.isDeleted,
        tagNames: List.unmodifiable(plan.value.tagNames),
      ),
      selection: _fromRustMutationSelection(plan.selection),
    );

NotebookMutationPlanValue _fromRustNotebookPlan(
  rust_mutations.NotebookMutationPlan plan,
) => (
  value: (
    name: plan.value.name,
    parentId: plan.value.parentId,
    sortOrder: plan.value.sortOrder,
    isDeleted: plan.value.isDeleted,
  ),
  selection: _fromRustMutationSelection(plan.selection),
);

TaskMutationPlanValue _fromRustTaskPlan(rust_mutations.TaskMutationPlan plan) =>
    (
      value: (
        title: plan.value.title,
        description: plan.value.description,
        noteId: plan.value.noteId,
        notebookId: plan.value.notebookId,
        parentId: plan.value.parentId,
        dueDateMicrosUtc: plan.value.dueDateMicrosUtc,
        dueHasTime: plan.value.dueHasTime,
        priority: plan.value.priority,
        labels: List.unmodifiable(plan.value.labels),
        recurrence: plan.value.recurrence,
        reminderAtMicrosUtc: plan.value.reminderAtMicrosUtc,
        reminderLeadMinutes: plan.value.reminderLeadMinutes,
        sortOrder: plan.value.sortOrder,
        isCompleted: plan.value.isCompleted,
        completedAtMicrosUtc: plan.value.completedAtMicrosUtc,
        isDeleted: plan.value.isDeleted,
      ),
      selection: _fromRustMutationSelection(plan.selection),
    );

// --- Task engine: repetition, ordering, quick add ---
//
// These delegate to `rust/src/api/tasks.rs` and `quickadd.rs`. Their Dart
// counterparts in the fallback are behaviourally equivalent for everything the
// list needs to render; quick-add parsing is the one deliberate exception,
// documented at `parseQuickAdd` below.

String serializeRecurrence(RecurrenceRuleValue rule) => _isInitialized
    ? rust_tasks.serializeRecurrence(rule: _toRustRecurrence(rule))
    : fallback.serializeRecurrence(rule);

RecurrenceRuleValue? parseRecurrence(String text) {
  if (!_isInitialized) return fallback.parseRecurrence(text);
  final rule = rust_tasks.parseRecurrence(text: text);
  return rule == null ? null : _fromRustRecurrence(rule);
}

String describeRecurrence(RecurrenceRuleValue rule) => _isInitialized
    ? rust_tasks.describeRecurrence(rule: _toRustRecurrence(rule))
    : fallback.describeRecurrence(rule);

/// The next date a rule fires on, strictly after [from] and never before
/// [notBefore]. Used to preview a repeat before it is saved.
CivilDateValue? nextOccurrence({
  required RecurrenceRuleValue rule,
  required CivilDateValue from,
  required CivilDateValue notBefore,
}) {
  if (!_isInitialized) {
    return fallback.nextOccurrence(rule: rule, from: from, notBefore: notBefore);
  }
  final next = rust_tasks.nextOccurrence(
    rule: _toRustRecurrence(rule),
    from: _toRustCivilDate(from),
    notBefore: _toRustCivilDate(notBefore),
  );
  return next == null ? null : _fromRustCivilDate(next);
}

RecurrenceAdvanceValue advanceOnCompletion({
  String? recurrence,
  CivilDateValue? due,
  required bool dueHasTime,
  required CivilDateValue completedOn,
}) {
  if (!_isInitialized) {
    return fallback.advanceOnCompletion(
      recurrence: recurrence,
      due: due,
      dueHasTime: dueHasTime,
      completedOn: completedOn,
    );
  }
  final advance = rust_tasks.advanceOnCompletion(
    recurrence: recurrence,
    due: due == null ? null : _toRustCivilDate(due),
    dueHasTime: dueHasTime,
    completedOn: _toRustCivilDate(completedOn),
  );
  return (
    nextDue: advance.nextDue == null
        ? null
        : _fromRustCivilDate(advance.nextDue!),
    keepsTime: advance.keepsTime,
  );
}

TaskViewPlanValue planTaskView({
  required List<TaskViewInputValue> tasks,
  required TaskViewContextValue context,
}) {
  if (!_isInitialized) {
    return fallback.planTaskView(tasks: tasks, context: context);
  }
  final plan = rust_tasks.planTaskView(
    tasks: [for (final task in tasks) _toRustTaskViewInput(task)],
    context: rust_tasks.TaskViewContext(
      today: _toRustCivilDate(context.today),
      focus: _toRustCivilDate(context.focus),
      sort: switch (context.sort) {
        CoreTaskSort.smart => rust_tasks.TaskSort.smart,
        CoreTaskSort.manual => rust_tasks.TaskSort.manual,
        CoreTaskSort.priority => rust_tasks.TaskSort.priority,
        CoreTaskSort.dueDate => rust_tasks.TaskSort.dueDate,
        CoreTaskSort.alphabetical => rust_tasks.TaskSort.alphabetical,
      },
      showCompleted: context.showCompleted,
      showAnytime: context.showAnytime,
    ),
  );
  return (
    sections: List.unmodifiable([
      for (final section in plan.sections)
        (
          kind: switch (section.kind) {
            rust_tasks.TaskSectionKind.overdue => CoreTaskSectionKind.overdue,
            rust_tasks.TaskSectionKind.focus => CoreTaskSectionKind.focus,
            rust_tasks.TaskSectionKind.anytime => CoreTaskSectionKind.anytime,
            rust_tasks.TaskSectionKind.completed =>
              CoreTaskSectionKind.completed,
          },
          label: section.label,
          rows: List<TaskRowValue>.unmodifiable([
            for (final row in section.rows)
              (
                id: row.id,
                depth: row.depth,
                childTotal: row.childTotal,
                childDone: row.childDone,
                isOverdue: row.isOverdue,
              ),
          ]),
        ),
    ]),
    openCount: plan.openCount,
    overdueCount: plan.overdueCount,
    completedCount: plan.completedCount,
  );
}

List<CalendarDayValue> monthDensity({
  required List<TaskViewInputValue> tasks,
  required int year,
  required int month,
  required CivilDateValue today,
}) {
  if (!_isInitialized) {
    return fallback.monthDensity(
      tasks: tasks,
      year: year,
      month: month,
      today: today,
    );
  }
  return List.unmodifiable([
    for (final day in rust_tasks.monthDensity(
      tasks: [for (final task in tasks) _toRustTaskViewInput(task)],
      year: year,
      month: month,
      today: _toRustCivilDate(today),
    ))
      (
        day: day.day,
        openCount: day.openCount,
        hasOverdue: day.hasOverdue,
        hasUrgent: day.hasUrgent,
        allDone: day.allDone,
      ),
  ]);
}

ReminderInstantValue? reminderTime({
  required CivilDateValue due,
  CivilTimeValue? dueTime,
  required int leadMinutes,
  int allDayHour = 9,
  int allDayMinute = 0,
}) {
  if (!_isInitialized) {
    return fallback.reminderTime(
      due: due,
      dueTime: dueTime,
      leadMinutes: leadMinutes,
      allDayHour: allDayHour,
      allDayMinute: allDayMinute,
    );
  }
  final fired = rust_tasks.reminderTime(
    due: _toRustCivilDate(due),
    dueTime: dueTime == null ? null : _toRustCivilTime(dueTime),
    leadMinutes: leadMinutes,
    allDayHour: allDayHour,
    allDayMinute: allDayMinute,
  );
  return fired == null
      ? null
      : (
          date: _fromRustCivilDate(fired.date),
          time: (hour: fired.time.hour, minute: fired.time.minute),
        );
}

List<SortAssignmentValue> planReorder({
  required List<String> orderedIds,
  required List<SortAssignmentValue> current,
}) {
  if (!_isInitialized) {
    return fallback.planReorder(orderedIds: orderedIds, current: current);
  }
  return List.unmodifiable([
    for (final change in rust_tasks.planReorder(
      orderedIds: orderedIds,
      current: [
        for (final entry in current)
          rust_tasks.SortAssignment(id: entry.id, sortOrder: entry.sortOrder),
      ],
    ))
      (id: change.id, sortOrder: change.sortOrder),
  ]);
}

/// Turn one typed line into a task.
///
/// Unlike the rest of the engine this has no Dart mirror. A second
/// natural-language grammar would drift from the first invisibly, and the
/// damage — a task silently filed on the wrong day — is worse than the
/// degradation: before the core is ready the line becomes the title verbatim,
/// which is exactly what the old sheet did.
QuickAddParseValue parseQuickAdd({
  required String text,
  required QuickAddContextValue context,
}) {
  if (!_isInitialized) return fallback.parseQuickAdd(text: text, context: context);
  final parsed = rust_quickadd.parseQuickAdd(
    text: text,
    context: rust_quickadd.QuickAddContext(
      today: _toRustCivilDate(context.today),
      now: _toRustCivilTime(context.now),
      todayWeekday: context.todayWeekday,
      weekStartMonday: context.weekStartMonday,
      monthFirst: context.monthFirst,
    ),
  );
  return (
    title: parsed.title,
    priority: parsed.priority,
    project: parsed.project,
    labels: List.unmodifiable(parsed.labels),
    due: parsed.due == null ? null : _fromRustCivilDate(parsed.due!),
    dueTime: parsed.dueTime == null
        ? null
        : (hour: parsed.dueTime!.hour, minute: parsed.dueTime!.minute),
    recurrence: parsed.recurrence,
    reminderLeadMinutes: parsed.reminderLeadMinutes,
    spans: List.unmodifiable([
      for (final span in parsed.spans)
        (
          start: span.start,
          end: span.end,
          kind: switch (span.kind) {
            rust_quickadd.QuickAddTokenKind.date => CoreQuickAddToken.date,
            rust_quickadd.QuickAddTokenKind.time => CoreQuickAddToken.time,
            rust_quickadd.QuickAddTokenKind.priority =>
              CoreQuickAddToken.priority,
            rust_quickadd.QuickAddTokenKind.project =>
              CoreQuickAddToken.project,
            rust_quickadd.QuickAddTokenKind.label => CoreQuickAddToken.label,
            rust_quickadd.QuickAddTokenKind.recurrence =>
              CoreQuickAddToken.recurrence,
            rust_quickadd.QuickAddTokenKind.reminder =>
              CoreQuickAddToken.reminder,
          },
        ),
    ]),
  );
}

rust_tasks.CivilDate _toRustCivilDate(CivilDateValue value) =>
    rust_tasks.CivilDate(
      year: value.year,
      month: value.month,
      day: value.day,
    );

CivilDateValue _fromRustCivilDate(rust_tasks.CivilDate value) =>
    (year: value.year, month: value.month, day: value.day);

rust_tasks.CivilTime _toRustCivilTime(CivilTimeValue value) =>
    rust_tasks.CivilTime(hour: value.hour, minute: value.minute);

rust_tasks.RecurrenceRule _toRustRecurrence(RecurrenceRuleValue value) =>
    rust_tasks.RecurrenceRule(
      freq: switch (value.freq) {
        CoreRecurrenceFreq.daily => rust_tasks.RecurrenceFreq.daily,
        CoreRecurrenceFreq.weekly => rust_tasks.RecurrenceFreq.weekly,
        CoreRecurrenceFreq.monthly => rust_tasks.RecurrenceFreq.monthly,
        CoreRecurrenceFreq.yearly => rust_tasks.RecurrenceFreq.yearly,
      },
      interval: value.interval,
      // The bridge maps Rust's `Vec<u32>` to a typed list.
      byWeekday: Uint32List.fromList(value.byWeekday),
      mode: switch (value.mode) {
        CoreRecurrenceMode.schedule => rust_tasks.RecurrenceMode.schedule,
        CoreRecurrenceMode.completion => rust_tasks.RecurrenceMode.completion,
      },
    );

RecurrenceRuleValue _fromRustRecurrence(rust_tasks.RecurrenceRule value) => (
  freq: switch (value.freq) {
    rust_tasks.RecurrenceFreq.daily => CoreRecurrenceFreq.daily,
    rust_tasks.RecurrenceFreq.weekly => CoreRecurrenceFreq.weekly,
    rust_tasks.RecurrenceFreq.monthly => CoreRecurrenceFreq.monthly,
    rust_tasks.RecurrenceFreq.yearly => CoreRecurrenceFreq.yearly,
  },
  interval: value.interval,
  byWeekday: List.unmodifiable(value.byWeekday),
  mode: switch (value.mode) {
    rust_tasks.RecurrenceMode.schedule => CoreRecurrenceMode.schedule,
    rust_tasks.RecurrenceMode.completion => CoreRecurrenceMode.completion,
  },
);

rust_tasks.TaskViewInput _toRustTaskViewInput(TaskViewInputValue value) =>
    rust_tasks.TaskViewInput(
      id: value.id,
      title: value.title,
      parentId: value.parentId,
      priority: value.priority,
      due: value.due == null ? null : _toRustCivilDate(value.due!),
      dueTime: value.dueTime == null ? null : _toRustCivilTime(value.dueTime!),
      isCompleted: value.isCompleted,
      completedOn: value.completedOn == null
          ? null
          : _toRustCivilDate(value.completedOn!),
      sortOrder: value.sortOrder,
      createdSeq: value.createdSeq,
    );

MutationSelectionValue _fromRustMutationSelection(
  rust_mutations.MutationSelection selection,
) => (
  action: switch (selection.action) {
    rust_mutations.MutationAction.noop => CoreMutationAction.noop,
    rust_mutations.MutationAction.create => CoreMutationAction.create,
    rust_mutations.MutationAction.update => CoreMutationAction.update,
    rust_mutations.MutationAction.delete => CoreMutationAction.delete,
  },
  changedFields: List.unmodifiable(selection.changedFields),
  patchFields: List.unmodifiable(selection.patchFields),
);

String _filenameStem(String filename) {
  final slash = filename.lastIndexOf(RegExp(r'[/\\]'));
  final base = slash >= 0 ? filename.substring(slash + 1) : filename;
  final dot = base.lastIndexOf('.');
  return dot > 0 ? base.substring(0, dot) : base;
}

// --- Scripts ---

ScriptReportValue detectScript(String text) {
  if (!_isInitialized) return fallback.detectScript(text);
  final report = rust_script.detectScript(text: text);
  return (
    script: ScriptValue.values[report.script.index],
    confidence: report.confidence,
    letters: report.letters,
    recognizable: report.recognizable,
  );
}

rust_script.ScriptReading _toRustReading(ScriptReadingValue reading) =>
    rust_script.ScriptReading(
      script: rust_script.TextScript.values[reading.script.index],
      page: _toRustPage(reading.page),
    );

ReadingScoreValue _fromRustScore(rust_script.ReadingScore score) => (
  script: ScriptValue.values[score.script.index],
  score: score.score,
  characters: score.characters,
  meanConfidence: score.meanConfidence,
  coverage: score.coverage,
  junkShare: score.junkShare,
  dominantScript: ScriptValue.values[score.dominantScript.index],
);

ReadingScoreValue scoreScriptReading({
  required ScriptValue script,
  required OcrPageValue page,
}) => _isInitialized
    ? _fromRustScore(
        rust_script.scoreScriptReading(
          reading: _toRustReading((script: script, page: page)),
        ),
      )
    : fallback.scoreScriptReading(script: script, page: page);

bool readingLooksWrong(ReadingScoreValue score) {
  if (!_isInitialized) return fallback.readingLooksWrong(score);
  return rust_script.readingLooksWrong(
    score: rust_script.ReadingScore(
      script: rust_script.TextScript.values[score.script.index],
      score: score.score,
      characters: score.characters,
      meanConfidence: score.meanConfidence,
      coverage: score.coverage,
      junkShare: score.junkShare,
      dominantScript:
          rust_script.TextScript.values[score.dominantScript.index],
    ),
  );
}

ScriptChoiceValue chooseScriptReading({
  required List<ScriptReadingValue> readings,
}) {
  if (!_isInitialized) return fallback.chooseScriptReading(readings: readings);
  final choice = rust_script.chooseScriptReading(
    readings: [for (final reading in readings) _toRustReading(reading)],
  );
  return (
    chosen: choice.chosen,
    script: ScriptValue.values[choice.script.index],
    scores: [for (final score in choice.scores) _fromRustScore(score)],
    reason: choice.reason,
  );
}

PageMeasureValue measurePage(OcrPageValue page) {
  if (!_isInitialized) return fallback.measurePage(page);
  final measure = rust_prepare.measurePage(page: _toRustPage(page));
  return (
    skewDegrees: measure.skewDegrees,
    medianLineHeight: measure.medianLineHeight,
    usableLines: measure.usableLines,
  );
}

PagePrepareValue planPagePrepare({
  required PageMeasureValue measure,
  required PageLumaSampleValue sample,
  required double width,
  required double height,
}) {
  if (!_isInitialized) {
    return fallback.planPagePrepare(
      measure: measure,
      sample: sample,
      width: width,
      height: height,
    );
  }
  final plan = rust_prepare.planPagePrepare(
    measure: rust_prepare.PageMeasure(
      skewDegrees: measure.skewDegrees,
      medianLineHeight: measure.medianLineHeight,
      usableLines: measure.usableLines,
    ),
    sample: rust_prepare.PageLumaSample(histogram: sample.histogram),
    width: width,
    height: height,
  );
  return (
    worthwhile: plan.worthwhile,
    outWidth: plan.outWidth,
    outHeight: plan.outHeight,
    transform: plan.transform,
    colorMatrix: plan.colorMatrix,
    rotateDegrees: plan.rotateDegrees,
    scale: plan.scale,
    reason: plan.reason,
  );
}

List<OcrLineValue> mapPreparedLinesToSource({
  required List<OcrLineValue> lines,
  required PagePrepareValue prepare,
}) {
  if (!_isInitialized) {
    return fallback.mapPreparedLinesToSource(lines: lines, prepare: prepare);
  }
  final mapped = rust_prepare.mapPreparedLinesToSource(
    lines: _toRustLines(lines),
    prepare: rust_prepare.PagePrepare(
      worthwhile: prepare.worthwhile,
      outWidth: prepare.outWidth,
      outHeight: prepare.outHeight,
      transform: prepare.transform,
      colorMatrix: prepare.colorMatrix,
      rotateDegrees: prepare.rotateDegrees,
      scale: prepare.scale,
      reason: prepare.reason,
    ),
  );
  return [for (final line in mapped) _fromRustLine(line)];
}

PageReadingChoiceValue choosePageReading({
  required List<OcrPageValue> readings,
}) {
  if (!_isInitialized) return fallback.choosePageReading(readings: readings);
  final choice = rust_prepare.choosePageReading(
    readings: [for (final page in readings) _toRustPage(page)],
  );
  return (
    chosen: choice.chosen,
    scores: [
      for (final score in choice.scores)
        (
          score: score.score,
          characters: score.characters,
          meanConfidence: score.meanConfidence,
          junkShare: score.junkShare,
          wordShare: score.wordShare,
        ),
    ],
    reason: choice.reason,
  );
}
