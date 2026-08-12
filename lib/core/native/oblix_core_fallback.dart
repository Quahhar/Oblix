import 'crdt_types.dart';
import 'dart:convert';

import 'package:dart_quill_delta/dart_quill_delta.dart';

// The pure-Dart task engine lives in its own file, mirroring how the Rust half
// is its own module. Re-exported so the fallback presents one flat surface.
export 'task_engine_dart.dart';

bool get isRustCoreReady => false;

Future<void> initializeOblixCore() async {}

CoreImportBundleValue parseEnexCore({
  required String xml,
  String? notebookName,
  required int nowMicrosUtc,
}) => _nativeCodecOnly();

List<int> exportEpubCore({
  required List<CoreEpubNoteValue> notes,
  required int exportedAtMicrosUtc,
  required String bookUuid,
}) => _nativeCodecOnly();

CoreImportBundleValue importEpubCore({
  required List<int> bytes,
  required int nowMicrosUtc,
}) => _nativeCodecOnly();

List<int> encodeOblixArchiveCore({
  required List<CoreOblixNoteValue> notes,
  required List<CoreOblixNotebookValue> notebooks,
  required List<String> tagNames,
  required List<CoreOblixAttachmentGroupValue> attachmentGroups,
  required int exportedAtMicrosUtc,
}) => _nativeCodecOnly();

CoreImportBundleValue decodeOblixArchiveCore({
  required List<int> bytes,
  required int nowMicrosUtc,
}) => _nativeCodecOnly();

Never _nativeCodecOnly() => throw StateError(
  'Rust archive codecs require an initialized native Oblix core.',
);

/// Dart oracle used on web and before the native library is initialized.
Set<String> remoteWinningFields({
  required Iterable<String> fields,
  required Map<String, CrdtClockValue> localClocks,
  required CrdtClockValue localFallback,
  required Map<String, CrdtClockValue> remoteClocks,
  required CrdtClockValue remoteFallback,
  Set<String> excludedFields = const {},
}) {
  final winners = <String>{};
  for (final field in fields) {
    if (excludedFields.contains(field)) continue;
    final local = localClocks[field] ?? localFallback;
    final remote = remoteClocks[field] ?? remoteFallback;
    final byTime = remote.timestampMicrosUtc.compareTo(
      local.timestampMicrosUtc,
    );
    final comparison = byTime != 0
        ? byTime
        : remote.deviceId.compareTo(local.deviceId);
    if (comparison > 0) winners.add(field);
  }
  return Set.unmodifiable(winners);
}

Map<String, CrdtClockValue> stampCrdtClockValues({
  required Map<String, CrdtClockValue> existing,
  required Iterable<String> fields,
  required int timestampMicrosUtc,
  required String deviceId,
}) {
  final clocks = <String, CrdtClockValue>{...existing};
  for (final field in fields) {
    clocks[field] = (
      timestampMicrosUtc: timestampMicrosUtc,
      deviceId: deviceId,
    );
  }
  return Map.unmodifiable(clocks);
}

int nextLogicalTimestampMicros({
  required int nowMicrosUtc,
  int? previousMicrosUtc,
}) => previousMicrosUtc != null && nowMicrosUtc <= previousMicrosUtc
    ? previousMicrosUtc + 1000
    : nowMicrosUtc;

bool collaborationTokenNeedsRefresh(String token, {required int nowSeconds}) {
  try {
    final pieces = token.split('.');
    final payload =
        jsonDecode(
              utf8.decode(base64Url.decode(base64Url.normalize(pieces[1]))),
            )
            as Map<String, dynamic>;
    final expires = payload['exp'] as int?;
    return expires == null || expires <= nowSeconds + 60;
  } on Object {
    return true;
  }
}

String? jwtSubject(String token) {
  try {
    final parts = token.split('.');
    if (parts.length != 3) return null;
    final map =
        jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))))
            as Map<String, dynamic>;
    return map['sub'] as String?;
  } on Object {
    return null;
  }
}

bool collaborationSnapshotIsStale({
  String? lastEpoch,
  int? lastRevision,
  required String incomingEpoch,
  required int incomingRevision,
}) =>
    lastEpoch == incomingEpoch &&
    lastRevision != null &&
    incomingRevision <= lastRevision;

String normalizeTaskTitle(String title) =>
    title.trim().isEmpty ? 'Untitled task' : title.trim();

String normalizeNoteTitle(String title) =>
    title.trim().isEmpty ? 'Untitled' : title.trim();

bool noteDraftIsEmpty({required String title, required String content}) =>
    title.trim().isEmpty && content.trim().isEmpty;

String noteShareText({required String title, required String content}) =>
    title.isEmpty || title == 'Untitled' ? content : '$title\n\n$content';

List<String> parseTagNames(String raw) {
  final names = <String>[];
  for (final part in raw.split(',')) {
    final name = part.trim();
    if (name.isNotEmpty && !names.contains(name)) names.add(name);
  }
  return List.unmodifiable(names);
}

String sanitizeSingleExportStem(String title) {
  final stem = title == 'Untitled' ? 'note' : title;
  final sanitized = stem
      .replaceAll(RegExp(r'[^a-zA-Z0-9\-\_\s]'), '')
      .replaceAll(RegExp(r'\s+'), '_');
  return sanitized.isEmpty ? 'note' : sanitized;
}

int clampImportedTimestampMicros({
  required int timestampMicrosUtc,
  required int nowMicrosUtc,
}) => timestampMicrosUtc > nowMicrosUtc ? nowMicrosUtc : timestampMicrosUtc;

bool remoteTimestampWinsEqual({
  required int localTimestampMicrosUtc,
  required int remoteTimestampMicrosUtc,
}) => remoteTimestampMicrosUtc >= localTimestampMicrosUtc;

int syncBackoffMillis({
  required int consecutiveFailures,
  required int baseMillis,
  required int maxMillis,
}) {
  if (consecutiveFailures <= 0 || baseMillis <= 0 || maxMillis <= 0) return 0;
  final shift = (consecutiveFailures - 1).clamp(0, 10);
  return (baseMillis * (1 << shift)).clamp(0, maxMillis);
}

PendingOutboxSummaryValue summarizePendingOutbox(
  List<PendingOutboxRowValue> rows,
) {
  final fields = <String>{};
  final updateSeqsByField = <String, Set<int>>{};
  for (final row in rows) {
    try {
      final data = jsonDecode(row.dataJson) as Map;
      final rowFields = data.keys.map((key) => key.toString());
      fields.addAll(rowFields);
      if (row.action == 'update') {
        for (final field in rowFields) {
          updateSeqsByField.putIfAbsent(field, () => <int>{}).add(row.seq);
        }
      }
    } on Object {
      fields.add('*');
    }
  }
  return (
    fields: Set.unmodifiable(fields),
    updateSeqsByField: Map.unmodifiable({
      for (final entry in updateSeqsByField.entries)
        entry.key: Set<int>.unmodifiable(entry.value),
    }),
  );
}

OutboxRetirementValue retireAcknowledgedOutboxField({
  required String dataJson,
  required String field,
}) {
  try {
    final data = (jsonDecode(dataJson) as Map).cast<String, dynamic>();
    if (!data.containsKey(field)) {
      return (changed: false, deleteRow: false, dataJson: dataJson);
    }
    data.remove(field);
    final rawClocks = data['field_clocks'];
    if (rawClocks is Map) {
      final clocks = rawClocks.cast<String, dynamic>();
      clocks.remove(field);
      if (clocks.isEmpty) {
        data.remove('field_clocks');
      } else {
        data['field_clocks'] = clocks;
      }
    }
    return (
      changed: true,
      deleteRow: data.isEmpty,
      dataJson: data.isEmpty ? '' : jsonEncode(data),
    );
  } on Object {
    return (changed: false, deleteRow: false, dataJson: dataJson);
  }
}

List<int> eligibleSyncSequences({
  required List<SyncBatchEntryValue> entries,
  required Set<String> protectedNoteIds,
}) => List.unmodifiable([
  for (final entry in entries)
    if (entry.entityType != 'note' ||
        !protectedNoteIds.contains(entry.entityId))
      entry.seq,
]);

SyncSettlementValue planSyncSettlement({
  required List<SyncBatchEntryValue> entries,
  required Set<String> decidedEntityIds,
  required bool protectedServerNoteSeen,
  required int batchSize,
  required List<int> pulledEntityCounts,
  required int droppedCount,
}) {
  final ackAll = entries.isNotEmpty && decidedEntityIds.isEmpty;
  final acked = <int>[];
  final retry = <int>[];
  for (final entry in entries) {
    (ackAll || decidedEntityIds.contains(entry.entityId) ? acked : retry).add(
      entry.seq,
    );
  }
  final pulled = pulledEntityCounts.fold(0, (sum, count) => sum + count);
  return (
    ackedSeqs: List.unmodifiable(acked),
    retrySeqs: List.unmodifiable(retry),
    pulledCount: pulled,
    anythingChanged: pulled > 0 || acked.isNotEmpty || droppedCount > 0,
    continueDraining:
        !protectedServerNoteSeen &&
        entries.length >= batchSize &&
        retry.isEmpty,
  );
}

List<NotebookPathValue> resolveNotebookPaths(List<NotebookNodeValue> nodes) {
  final byId = {for (final node in nodes) node.id: node};
  final memo = <String, List<String>>{};
  List<String> resolve(NotebookNodeValue node, Set<String> visiting) {
    final cached = memo[node.id];
    if (cached != null) return cached;
    if (!visiting.add(node.id)) return [node.name];
    final parent = node.parentId == null ? null : byId[node.parentId];
    final path = parent == null
        ? [node.name]
        : [...resolve(parent, visiting), node.name];
    visiting.remove(node.id);
    memo[node.id] = path;
    return path;
  }

  return List.unmodifiable([
    for (final node in nodes)
      (
        id: node.id,
        path: List<String>.unmodifiable(resolve(node, <String>{})),
        pathKey: notebookPathKey(resolve(node, <String>{})),
      ),
  ]);
}

List<String> selectExportNotebookIds({
  required Iterable<String> noteNotebookIds,
  required List<NotebookNodeValue> notebooks,
}) {
  final byId = {for (final notebook in notebooks) notebook.id: notebook};
  final selected = <String>{};
  for (final start in noteNotebookIds) {
    String? id = start;
    while (id != null && selected.add(id)) {
      id = byId[id]?.parentId;
    }
  }
  return List.unmodifiable([
    for (final notebook in notebooks)
      if (selected.contains(notebook.id)) notebook.id,
  ]);
}

String notebookPathKey(List<String> path) =>
    path.map((part) => '${part.length}:$part').join();

List<Map<String, dynamic>> plainTextDiff(String before, String after) =>
    (Delta()..insert(before)).diff(Delta()..insert(after)).toJson();

String applyPlainTextDelta(String text, List<dynamic> delta) {
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

List<int> transformTextPositions({
  required String before,
  required String after,
  required List<int> positions,
}) {
  final delta = Delta.fromJson(plainTextDiff(before, after));
  return List.unmodifiable([
    for (final position in positions)
      (position < 0 ? after.length : delta.transformPosition(position)).clamp(
        0,
        after.length,
      ),
  ]);
}

String rebasePlainText({
  required String oldServer,
  required String newServer,
  required String local,
  List<dynamic>? serverChange,
}) {
  if (local == oldServer) return newServer;
  final localChange = Delta.fromJson(plainTextDiff(oldServer, local));
  final canonicalChange = serverChange == null
      ? Delta.fromJson(plainTextDiff(oldServer, newServer))
      : Delta.fromJson(serverChange);
  final transformed = canonicalChange.transform(localChange, true);
  return applyPlainTextDelta(newServer, transformed.toJson());
}

String noteSnippet(String content) =>
    content.replaceAll(RegExp(r'\s+'), ' ').trim();

const _monthLabels = [
  'JANUARY',
  'FEBRUARY',
  'MARCH',
  'APRIL',
  'MAY',
  'JUNE',
  'JULY',
  'AUGUST',
  'SEPTEMBER',
  'OCTOBER',
  'NOVEMBER',
  'DECEMBER',
];

List<NoteDayGroupValue> groupNotesByDay({
  required List<NoteDayValue> notes,
  required int todayYear,
  required int todayMonth,
  required int todayDay,
}) {
  final today = DateTime(todayYear, todayMonth, todayDay);
  final order = <String>[];
  final byLabel = <String, List<String>>{};
  for (final note in notes) {
    final label = _dayGroupLabel(note, today);
    if (byLabel.putIfAbsent(label, () => <String>[]).isEmpty) order.add(label);
    byLabel[label]!.add(note.id);
  }
  return List.unmodifiable([
    for (final label in order)
      (label: label, noteIds: List<String>.unmodifiable(byLabel[label]!)),
  ]);
}

String _dayGroupLabel(NoteDayValue note, DateTime today) {
  final day = DateTime(note.localYear, note.localMonth, note.localDay);
  final days = today.difference(day).inDays;
  if (days <= 0) return 'TODAY';
  if (days == 1) return 'YESTERDAY';
  if (days < 7) return 'PREVIOUS 7 DAYS';
  if (days < 30) return 'PREVIOUS 30 DAYS';
  // Older than a month: the month alone inside the current year, the year once
  // the note predates it. Dropping the day is the point — a heading per day is
  // what turned a long list into headings with notes in the gaps.
  if (day.year != today.year) return '${day.year}';
  return _monthLabels[day.month - 1];
}

/// Page reconstruction is native-only, like the archive codecs.
///
/// There is deliberately no Dart mirror of it. The other migrated algorithms
/// keep one because they run on web and because a second implementation makes
/// a differential-test oracle — neither applies here. Scanning needs a
/// recognizer that only exists on Android and iOS, where the native core is
/// always initialized, so a mirror would be several hundred lines of geometry
/// that nothing executes and that could silently drift from `api/ocr.rs`.
/// The Rust module carries the test suite instead.
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
}) => throw _scanningIsNativeOnly();

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
}) => throw _scanningIsNativeOnly();

/// Text layers, entity extraction and PDF reading are native-only for the same
/// reason page reconstruction is: they exist to serve scanning, which needs a
/// recognizer or a PDF renderer that only the native platforms have. Mirroring
/// several thousand lines of geometry, pattern matching and coordinate
/// arithmetic in Dart would produce code nothing runs and that could drift
/// from the Rust unnoticed. Refusing is the honest answer — a second
/// implementation quietly returning a *different* answer is the dangerous one.
StateError _scanningIsNativeOnly() => StateError(
  'Scanned page reconstruction requires an initialized native Oblix core.',
);

TextLayerValue buildTextLayer({
  required List<OcrPageValue> pages,
  required String source,
}) => throw _scanningIsNativeOnly();

List<OcrPageValue> textLayerToPages(TextLayerValue layer) =>
    throw _scanningIsNativeOnly();

String encodeTextLayer(TextLayerValue layer) => throw _scanningIsNativeOnly();

TextLayerValue decodeTextLayer(String encoded) => throw _scanningIsNativeOnly();

String textLayerSearchText(TextLayerValue layer) =>
    throw _scanningIsNativeOnly();

List<TextLayerHitValue> findInTextLayer({
  required TextLayerValue layer,
  required String query,
}) => throw _scanningIsNativeOnly();

String textLayerRegion({
  required TextLayerValue layer,
  required int page,
  required double left,
  required double top,
  required double right,
  required double bottom,
}) => throw _scanningIsNativeOnly();

String textLayerFingerprint(TextLayerValue layer) =>
    throw _scanningIsNativeOnly();

int fingerprintDistance(String left, String right) =>
    throw _scanningIsNativeOnly();

bool textLayerLooksDuplicate(String left, String right) =>
    throw _scanningIsNativeOnly();

List<EntityValue> extractEntities({
  required String text,
  bool dayFirst = true,
}) => throw _scanningIsNativeOnly();

List<RedactionSpanValue> findRedactions({
  required TextLayerValue layer,
  List<EntityKindValue> kinds = const [],
  bool dayFirst = true,
}) => throw _scanningIsNativeOnly();

List<SuggestedActionValue> suggestActions({
  required String text,
  bool dayFirst = true,
}) => throw _scanningIsNativeOnly();

PdfPageAssessmentValue assessPdfPage(PdfPageValue page) =>
    throw _scanningIsNativeOnly();

List<OcrPageValue> pdfPagesToOcrPages({
  required List<PdfPageValue> pages,
  double scale = 1,
}) => throw _scanningIsNativeOnly();

MarkdownImportValue parseMarkdownTextCore(String text, String filename) {
  final lines = text
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n');
  final clean = <String>[];
  String? title;
  var headingFound = false;
  for (final line in lines) {
    if (!headingFound) {
      final trimmed = line.trimLeft();
      if (trimmed.startsWith('#') &&
          !trimmed.startsWith('##') &&
          line.trim().isNotEmpty) {
        title = trimmed.substring(1).trim();
        title = title.isEmpty ? null : title;
        headingFound = true;
        continue;
      }
    }
    clean.add(line);
  }
  final content = clean.join('\n').replaceFirst(RegExp(r'^\n+'), '');
  return (
    title: title ?? _filenameStem(filename),
    content: content,
    contentType: filename.toLowerCase().endsWith('.md') ? 'markdown' : 'plain',
  );
}

String renderNoteMarkdown(ExportNoteValue note) {
  final title = note.title == 'Untitled' ? '' : note.title;
  final output = StringBuffer()
    ..writeln('# ${title.isNotEmpty ? title : 'Untitled'}')
    ..writeln()
    ..write(note.content);
  if (note.tagNames.isNotEmpty) {
    output
      ..writeln()
      ..writeln()
      ..write('Tags: ${note.tagNames.join(', ')}');
  }
  return output.toString();
}

String renderNoteText(ExportNoteValue note) {
  final title = note.title.trim();
  final body = note.content.trimRight();
  return title.isEmpty || title == 'Untitled' ? body : '$title\n\n$body';
}

List<ExportTextFileValue> renderMarkdownFiles(List<ExportNoteValue> notes) =>
    _renderFiles(notes, 'md', renderNoteMarkdown);

List<ExportTextFileValue> renderTextFiles(List<ExportNoteValue> notes) =>
    _renderFiles(notes, 'txt', renderNoteText);

NoteMutationPlanValue planNoteCreate({
  required String title,
  required String content,
  required String contentType,
  String? notebookId,
  bool isPinned = false,
  bool isArchived = false,
  List<String> tagNames = const [],
}) => (
  value: (
    title: title,
    content: content,
    contentType: contentType,
    notebookId: notebookId,
    isPinned: isPinned,
    isArchived: isArchived,
    isDeleted: false,
    tagNames: List.unmodifiable(tagNames),
  ),
  selection: _mutationSelection(CoreMutationAction.create, const [
    'title',
    'content',
    'content_type',
    'notebook_id',
    'is_pinned',
    'is_archived',
    'tags',
    'is_deleted',
  ]),
);

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
  final changed = <String>[
    if (title != null) 'title',
    if (content != null) 'content',
    if (contentType != null) 'content_type',
    if (notebookIdProvided) 'notebook_id',
    if (isPinned != null) 'is_pinned',
    if (isArchived != null) 'is_archived',
    if (tagNames != null) 'tags',
  ];
  return (
    value: (
      title: title ?? current.title,
      content: content ?? current.content,
      contentType: contentType ?? current.contentType,
      notebookId: notebookIdProvided ? notebookId : current.notebookId,
      isPinned: isPinned ?? current.isPinned,
      isArchived: isArchived ?? current.isArchived,
      isDeleted: current.isDeleted,
      tagNames: List.unmodifiable(tagNames ?? current.tagNames),
    ),
    selection: _mutationSelection(CoreMutationAction.update, changed),
  );
}

NoteMutationPlanValue planNoteDelete(NoteMutationStateValue current) => (
  value: (
    title: current.title,
    content: current.content,
    contentType: current.contentType,
    notebookId: current.notebookId,
    isPinned: current.isPinned,
    isArchived: false,
    isDeleted: true,
    tagNames: current.tagNames,
  ),
  selection: _mutationSelection(CoreMutationAction.delete, const [
    'is_deleted',
    'is_archived',
  ]),
);

NoteMutationPlanValue planNoteRestore(NoteMutationStateValue current) => (
  value: (
    title: current.title,
    content: current.content,
    contentType: current.contentType,
    notebookId: current.notebookId,
    isPinned: current.isPinned,
    isArchived: current.isArchived,
    isDeleted: false,
    tagNames: current.tagNames,
  ),
  selection: _mutationSelection(CoreMutationAction.update, const [
    'is_deleted',
  ]),
);

NotebookMutationPlanValue planNotebookCreate({
  required String name,
  String? parentId,
  int sortOrder = 0,
}) => (
  value: (
    name: name,
    parentId: parentId,
    sortOrder: sortOrder,
    isDeleted: false,
  ),
  selection: _mutationSelection(CoreMutationAction.create, const [
    'name',
    'parent_id',
    'sort_order',
    'is_deleted',
  ]),
);

NotebookMutationPlanValue planNotebookUpdate({
  required NotebookMutationStateValue current,
  String? name,
  bool parentIdProvided = false,
  String? parentId,
  int? sortOrder,
}) {
  final changed = <String>[
    if (name != null) 'name',
    if (parentIdProvided) 'parent_id',
    if (sortOrder != null) 'sort_order',
  ];
  return (
    value: (
      name: name ?? current.name,
      parentId: parentIdProvided ? parentId : current.parentId,
      sortOrder: sortOrder ?? current.sortOrder,
      isDeleted: current.isDeleted,
    ),
    selection: _mutationSelection(CoreMutationAction.update, changed),
  );
}

NotebookMutationPlanValue planNotebookDelete(
  NotebookMutationStateValue current,
) => (
  value: (
    name: current.name,
    parentId: current.parentId,
    sortOrder: current.sortOrder,
    isDeleted: true,
  ),
  selection: _mutationSelection(CoreMutationAction.delete, const [
    'is_deleted',
  ]),
);

/// Registers a task converges on, in the order the create plan stamps them.
/// Mirrors `TASK_FIELDS` in `rust/src/api/mutations.rs`.
const List<String> _taskFields = [
  'title',
  'description',
  'note_id',
  'due_date',
  'sort_order',
  'is_completed',
  'is_deleted',
  'priority',
  'labels',
  'recurrence',
  'reminder_at',
  'reminder_lead_minutes',
  'notebook_id',
  'parent_id',
];

const int _maxLabels = 32;
const int _maxLabelLength = 64;

int _clampPriority(int value) => value.clamp(0, 3);

int? _clampLead(int? value) => value?.clamp(0, 40320);

String? _normalizeRecurrence(String? value) =>
    (value == null || value.isEmpty) ? null : value;

List<String> _normalizeLabels(List<String> labels) {
  final seen = <String>{};
  final out = <String>[];
  for (final label in labels) {
    final trimmed = label.trim();
    if (trimmed.isEmpty) continue;
    final bounded = trimmed.length > _maxLabelLength
        ? trimmed.substring(0, _maxLabelLength)
        : trimmed;
    if (!seen.add(bounded.toLowerCase())) continue;
    out.add(bounded);
    if (out.length >= _maxLabels) break;
  }
  return List.unmodifiable(out);
}

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
}) => (
  value: (
    title: normalizeTaskTitle(title),
    description: description,
    noteId: noteId,
    notebookId: notebookId,
    parentId: parentId,
    dueDateMicrosUtc: dueDateMicrosUtc,
    dueHasTime: dueHasTime && dueDateMicrosUtc != null,
    priority: _clampPriority(priority),
    labels: _normalizeLabels(labels),
    recurrence: _normalizeRecurrence(recurrence),
    reminderAtMicrosUtc: reminderAtMicrosUtc,
    reminderLeadMinutes: _clampLead(reminderLeadMinutes),
    sortOrder: sortOrder,
    isCompleted: false,
    completedAtMicrosUtc: null,
    isDeleted: false,
  ),
  selection: _mutationSelection(CoreMutationAction.create, _taskFields),
);

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
  final nextPriority = priority == null ? null : _clampPriority(priority);
  final nextLabels = labels == null ? null : _normalizeLabels(labels);
  // due_has_time shares the due_date register, so either one moving stamps
  // that register exactly once.
  final dueTouched = dueDateProvided || dueHasTime != null;
  final nextDue = dueDateProvided ? dueDateMicrosUtc : current.dueDateMicrosUtc;

  final changed = <String>[
    if (title != null && title != current.title) 'title',
    if (description != null && description != current.description)
      'description',
    if (noteIdProvided) 'note_id',
    if (notebookIdProvided) 'notebook_id',
    if (parentIdProvided) 'parent_id',
    if (dueTouched) 'due_date',
    if (nextPriority != null && nextPriority != current.priority) 'priority',
    if (nextLabels != null && !_sameLabels(nextLabels, current.labels))
      'labels',
    if (recurrenceProvided) 'recurrence',
    if (reminderAtProvided) 'reminder_at',
    if (reminderLeadProvided) 'reminder_lead_minutes',
    if (sortOrder != null && sortOrder != current.sortOrder) 'sort_order',
  ];
  return (
    value: (
      title: changed.contains('title') ? title! : current.title,
      description: changed.contains('description')
          ? description!
          : current.description,
      noteId: noteIdProvided ? noteId : current.noteId,
      notebookId: notebookIdProvided ? notebookId : current.notebookId,
      parentId: parentIdProvided ? parentId : current.parentId,
      dueDateMicrosUtc: nextDue,
      dueHasTime: (dueHasTime ?? current.dueHasTime) && nextDue != null,
      priority: changed.contains('priority')
          ? nextPriority!
          : current.priority,
      labels: changed.contains('labels') ? nextLabels! : current.labels,
      recurrence: recurrenceProvided
          ? _normalizeRecurrence(recurrence)
          : current.recurrence,
      reminderAtMicrosUtc: reminderAtProvided
          ? reminderAtMicrosUtc
          : current.reminderAtMicrosUtc,
      reminderLeadMinutes: reminderLeadProvided
          ? _clampLead(reminderLeadMinutes)
          : current.reminderLeadMinutes,
      sortOrder: changed.contains('sort_order')
          ? sortOrder!
          : current.sortOrder,
      isCompleted: current.isCompleted,
      completedAtMicrosUtc: current.completedAtMicrosUtc,
      isDeleted: current.isDeleted,
    ),
    selection: _mutationSelection(CoreMutationAction.update, changed),
  );
}

bool _sameLabels(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var i = 0; i < left.length; i++) {
    if (left[i] != right[i]) return false;
  }
  return true;
}

TaskMutationPlanValue planTaskCompletion({
  required TaskMutationStateValue current,
  required bool completed,
  required int timestampMicrosUtc,
}) {
  if (current.isCompleted == completed) {
    return (
      value: current,
      selection: _mutationSelection(CoreMutationAction.noop, const []),
    );
  }
  return (
    value: (
      title: current.title,
      description: current.description,
      noteId: current.noteId,
      notebookId: current.notebookId,
      parentId: current.parentId,
      dueDateMicrosUtc: current.dueDateMicrosUtc,
      dueHasTime: current.dueHasTime,
      priority: current.priority,
      labels: current.labels,
      recurrence: current.recurrence,
      reminderAtMicrosUtc: current.reminderAtMicrosUtc,
      reminderLeadMinutes: current.reminderLeadMinutes,
      sortOrder: current.sortOrder,
      isCompleted: completed,
      completedAtMicrosUtc: completed ? timestampMicrosUtc : null,
      isDeleted: current.isDeleted,
    ),
    selection: _mutationSelection(CoreMutationAction.update, const [
      'is_completed',
    ]),
  );
}

TaskMutationPlanValue planTaskRollover({
  required TaskMutationStateValue current,
  int? nextDueMicrosUtc,
  int? nextReminderMicrosUtc,
}) {
  if (nextDueMicrosUtc == null) {
    return (
      value: current,
      selection: _mutationSelection(CoreMutationAction.noop, const []),
    );
  }
  final reminderMoved =
      current.reminderAtMicrosUtc != nextReminderMicrosUtc;
  final changed = <String>[
    'due_date',
    if (reminderMoved) 'reminder_at',
    if (current.isCompleted) 'is_completed',
  ];
  return (
    value: (
      title: current.title,
      description: current.description,
      noteId: current.noteId,
      notebookId: current.notebookId,
      parentId: current.parentId,
      dueDateMicrosUtc: nextDueMicrosUtc,
      dueHasTime: current.dueHasTime,
      priority: current.priority,
      labels: current.labels,
      recurrence: current.recurrence,
      reminderAtMicrosUtc: reminderMoved
          ? nextReminderMicrosUtc
          : current.reminderAtMicrosUtc,
      reminderLeadMinutes: current.reminderLeadMinutes,
      sortOrder: current.sortOrder,
      isCompleted: false,
      completedAtMicrosUtc: null,
      isDeleted: current.isDeleted,
    ),
    selection: _mutationSelection(CoreMutationAction.update, changed),
  );
}

TaskMutationPlanValue planTaskDelete(TaskMutationStateValue current) => (
  value: (
    title: current.title,
    description: current.description,
    noteId: current.noteId,
    notebookId: current.notebookId,
    parentId: current.parentId,
    dueDateMicrosUtc: current.dueDateMicrosUtc,
    dueHasTime: current.dueHasTime,
    priority: current.priority,
    labels: current.labels,
    recurrence: current.recurrence,
    reminderAtMicrosUtc: current.reminderAtMicrosUtc,
    reminderLeadMinutes: current.reminderLeadMinutes,
    sortOrder: current.sortOrder,
    isCompleted: current.isCompleted,
    completedAtMicrosUtc: current.completedAtMicrosUtc,
    isDeleted: true,
  ),
  selection: _mutationSelection(CoreMutationAction.delete, const [
    'is_deleted',
  ]),
);

MutationSelectionValue _mutationSelection(
  CoreMutationAction requestedAction,
  List<String> changedFields,
) {
  if (changedFields.isEmpty) {
    return (
      action: CoreMutationAction.noop,
      changedFields: const [],
      patchFields: const [],
    );
  }
  return (
    action: requestedAction,
    changedFields: List.unmodifiable(changedFields),
    patchFields: List.unmodifiable([
      for (final field in changedFields) ...[
        field,
        // Companions: values carried by another field's register.
        if (field == 'is_completed') 'completed_at',
        if (field == 'due_date') 'due_has_time',
      ],
      'field_clocks',
    ]),
  );
}

List<ExportTextFileValue> _renderFiles(
  List<ExportNoteValue> notes,
  String extension,
  String Function(ExportNoteValue) render,
) {
  final seen = <String, int>{};
  return List.unmodifiable([
    for (final note in notes)
      () {
        final stem = _sanitisedStem(note.title, note.id);
        var filename = '$stem.$extension';
        if (seen.containsKey(filename)) {
          final index = seen[filename]! + 1;
          seen[filename] = index;
          filename = '$stem-$index.$extension';
        } else {
          seen[filename] = 1;
        }
        return (filename: filename, content: render(note));
      }(),
  ]);
}

String _sanitisedStem(String title, String id) {
  var stem = title
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9\-\_\s]'), '')
      .replaceAll(RegExp(r'\s+'), '-')
      .trim();
  if (stem.isEmpty) stem = 'untitled';
  if (stem.length > 60) {
    stem = stem.substring(0, 60).replaceAll(RegExp(r'-+$'), '');
  }
  final suffix = id.length >= 6 ? id.substring(id.length - 6) : id;
  return '$stem-$suffix';
}

String _filenameStem(String filename) {
  final slash = filename.lastIndexOf(RegExp(r'[/\\]'));
  final base = slash >= 0 ? filename.substring(slash + 1) : filename;
  final dot = base.lastIndexOf('.');
  return dot > 0 ? base.substring(0, dot) : base;
}

ScriptReportValue detectScript(String text) => throw _scanningIsNativeOnly();

ReadingScoreValue scoreScriptReading({
  required ScriptValue script,
  required OcrPageValue page,
}) => throw _scanningIsNativeOnly();

bool readingLooksWrong(ReadingScoreValue score) =>
    throw _scanningIsNativeOnly();

ScriptChoiceValue chooseScriptReading({
  required List<ScriptReadingValue> readings,
}) => throw _scanningIsNativeOnly();

PageMeasureValue measurePage(OcrPageValue page) =>
    throw _scanningIsNativeOnly();

PagePrepareValue planPagePrepare({
  required PageMeasureValue measure,
  required PageLumaSampleValue sample,
  required double width,
  required double height,
}) => throw _scanningIsNativeOnly();

List<OcrLineValue> mapPreparedLinesToSource({
  required List<OcrLineValue> lines,
  required PagePrepareValue prepare,
}) => throw _scanningIsNativeOnly();

PageReadingChoiceValue choosePageReading({
  required List<OcrPageValue> readings,
}) => throw _scanningIsNativeOnly();
