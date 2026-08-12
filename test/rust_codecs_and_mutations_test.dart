import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oblix/core/native/oblix_core.dart';
import 'package:oblix/core/native/oblix_core_fallback.dart' as dart_oracle;
import 'package:oblix/data/io/enex_parser.dart';
import 'package:oblix/data/io/epub_exporter.dart';
import 'package:oblix/data/io/epub_importer.dart';
import 'package:oblix/data/io/oblix_archive.dart';
import 'package:oblix/data/models/note.dart';
import 'package:oblix/data/models/notebook.dart';
import 'package:oblix/data/models/tag.dart';

Map<String, Object?> _notePlanShape(NoteMutationPlanValue plan) => {
  'title': plan.value.title,
  'content': plan.value.content,
  'contentType': plan.value.contentType,
  'notebookId': plan.value.notebookId,
  'isPinned': plan.value.isPinned,
  'isArchived': plan.value.isArchived,
  'isDeleted': plan.value.isDeleted,
  'tagNames': plan.value.tagNames,
  'action': plan.selection.action.name,
  'changedFields': plan.selection.changedFields,
  'patchFields': plan.selection.patchFields,
};

Map<String, Object?> _notebookPlanShape(NotebookMutationPlanValue plan) => {
  'name': plan.value.name,
  'parentId': plan.value.parentId,
  'sortOrder': plan.value.sortOrder,
  'isDeleted': plan.value.isDeleted,
  'action': plan.selection.action.name,
  'changedFields': plan.selection.changedFields,
  'patchFields': plan.selection.patchFields,
};

Map<String, Object?> _taskPlanShape(TaskMutationPlanValue plan) => {
  'title': plan.value.title,
  'description': plan.value.description,
  'noteId': plan.value.noteId,
  'notebookId': plan.value.notebookId,
  'parentId': plan.value.parentId,
  'dueDateMicrosUtc': plan.value.dueDateMicrosUtc,
  'dueHasTime': plan.value.dueHasTime,
  'priority': plan.value.priority,
  'labels': plan.value.labels,
  'recurrence': plan.value.recurrence,
  'reminderAtMicrosUtc': plan.value.reminderAtMicrosUtc,
  'reminderLeadMinutes': plan.value.reminderLeadMinutes,
  'sortOrder': plan.value.sortOrder,
  'isCompleted': plan.value.isCompleted,
  'completedAtMicrosUtc': plan.value.completedAtMicrosUtc,
  'isDeleted': plan.value.isDeleted,
  'action': plan.selection.action.name,
  'changedFields': plan.selection.changedFields,
  'patchFields': plan.selection.patchFields,
};

/// A task state with every register at a non-default value, so a differential
/// comparison actually exercises the fields rather than agreeing on nulls.
const TaskMutationStateValue _sampleTask = (
  title: 'Task',
  description: 'Body',
  noteId: 'note-1',
  notebookId: 'notebook-1',
  parentId: 'parent-1',
  dueDateMicrosUtc: 1000,
  dueHasTime: true,
  priority: 2,
  labels: ['email'],
  recurrence: 'FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TH',
  reminderAtMicrosUtc: 900,
  reminderLeadMinutes: 30,
  sortOrder: 2,
  isCompleted: false,
  completedAtMicrosUtc: null,
  isDeleted: false,
);

List<int> _oblixTimestampFixture(List<Map<String, Object?>> notes) {
  final manifest = utf8.encode(
    jsonEncode({'format': OblixArchive.formatId, 'version': 1}),
  );
  final data = utf8.encode(
    jsonEncode({'notes': notes, 'notebooks': const [], 'tags': const []}),
  );
  final archive = Archive()
    ..addFile(ArchiveFile(OblixArchive.manifestName, manifest.length, manifest))
    ..addFile(ArchiveFile(OblixArchive.dataName, data.length, data));
  return ZipEncoder().encode(archive);
}

void main() {
  setUpAll(() async {
    await initializeOblixCore();
  });

  test('native mutation planners match the Dart compatibility oracle', () {
    const note = (
      title: 'Current',
      content: 'Body',
      contentType: 'plain',
      notebookId: 'inbox',
      isPinned: false,
      isArchived: true,
      isDeleted: false,
      tagNames: <String>['work'],
    );
    final nativeNote = planNoteUpdate(
      current: note,
      title: 'Current',
      notebookIdProvided: true,
      notebookId: null,
      isPinned: true,
      tagNames: const ['work', 'urgent'],
    );
    final dartNote = dart_oracle.planNoteUpdate(
      current: note,
      title: 'Current',
      notebookIdProvided: true,
      notebookId: null,
      isPinned: true,
      tagNames: const ['work', 'urgent'],
    );
    expect(_notePlanShape(nativeNote), _notePlanShape(dartNote));
    expect(
      _notePlanShape(planNoteDelete(note)),
      _notePlanShape(dart_oracle.planNoteDelete(note)),
    );

    const notebook = (
      name: 'Projects',
      parentId: 'work',
      sortOrder: 3,
      isDeleted: false,
    );
    expect(
      _notebookPlanShape(
        planNotebookUpdate(
          current: notebook,
          parentIdProvided: true,
          parentId: null,
          sortOrder: 9,
        ),
      ),
      _notebookPlanShape(
        dart_oracle.planNotebookUpdate(
          current: notebook,
          parentIdProvided: true,
          parentId: null,
          sortOrder: 9,
        ),
      ),
    );

    const task = _sampleTask;
    expect(
      _taskPlanShape(
        planTaskUpdate(
          current: task,
          title: 'Renamed',
          noteIdProvided: true,
          noteId: null,
          dueDateProvided: true,
          dueDateMicrosUtc: null,
        ),
      ),
      _taskPlanShape(
        dart_oracle.planTaskUpdate(
          current: task,
          title: 'Renamed',
          noteIdProvided: true,
          noteId: null,
          dueDateProvided: true,
          dueDateMicrosUtc: null,
        ),
      ),
    );
    expect(
      _taskPlanShape(
        planTaskCompletion(
          current: task,
          completed: true,
          timestampMicrosUtc: 4242,
        ),
      ),
      _taskPlanShape(
        dart_oracle.planTaskCompletion(
          current: task,
          completed: true,
          timestampMicrosUtc: 4242,
        ),
      ),
    );

    // Every new register, in one update, compared field by field.
    Map<String, Object?> everything(
      TaskMutationPlanValue Function({
        required TaskMutationStateValue current,
        String? title,
        bool notebookIdProvided,
        String? notebookId,
        bool parentIdProvided,
        String? parentId,
        bool dueDateProvided,
        int? dueDateMicrosUtc,
        bool? dueHasTime,
        int? priority,
        List<String>? labels,
        bool recurrenceProvided,
        String? recurrence,
        bool reminderAtProvided,
        int? reminderAtMicrosUtc,
        bool reminderLeadProvided,
        int? reminderLeadMinutes,
      })
      planner,
    ) => _taskPlanShape(
      planner(
        current: task,
        notebookIdProvided: true,
        notebookId: 'notebook-2',
        parentIdProvided: true,
        parentId: null,
        dueDateProvided: true,
        dueDateMicrosUtc: 5000,
        dueHasTime: false,
        priority: 3,
        labels: const ['  Calls  ', 'calls', 'Email'],
        recurrenceProvided: true,
        recurrence: 'FREQ=DAILY;INTERVAL=3;MODE=COMPLETION',
        reminderAtProvided: true,
        reminderAtMicrosUtc: 4000,
        reminderLeadProvided: true,
        reminderLeadMinutes: 120,
      ),
    );
    expect(everything(planTaskUpdate), everything(dart_oracle.planTaskUpdate));

    // Rolling a repeating task forward is the same decision on both sides.
    expect(
      _taskPlanShape(
        planTaskRollover(
          current: task,
          nextDueMicrosUtc: 90000,
          nextReminderMicrosUtc: 88000,
        ),
      ),
      _taskPlanShape(
        dart_oracle.planTaskRollover(
          current: task,
          nextDueMicrosUtc: 90000,
          nextReminderMicrosUtc: 88000,
        ),
      ),
    );
  });

  test('mutation planners preserve sort orders outside the i32 range', () {
    const highSortOrder = 2147483648;
    const lowSortOrder = -2147483649;
    const notebook = (
      name: 'Projects',
      parentId: null,
      sortOrder: highSortOrder,
      isDeleted: false,
    );
    const task = (
      title: 'Task',
      description: '',
      noteId: null,
      notebookId: null,
      parentId: null,
      dueDateMicrosUtc: null,
      dueHasTime: false,
      priority: 0,
      labels: <String>[],
      recurrence: null,
      reminderAtMicrosUtc: null,
      reminderLeadMinutes: null,
      sortOrder: lowSortOrder,
      isCompleted: false,
      completedAtMicrosUtc: null,
      isDeleted: false,
    );

    final nativeNotebook = planNotebookUpdate(
      current: notebook,
      name: 'Renamed',
    );
    final nativeTask = planTaskUpdate(current: task, title: 'Renamed');

    expect(
      _notebookPlanShape(nativeNotebook),
      _notebookPlanShape(
        dart_oracle.planNotebookUpdate(current: notebook, name: 'Renamed'),
      ),
    );
    expect(nativeNotebook.value.sortOrder, highSortOrder);
    expect(
      _taskPlanShape(nativeTask),
      _taskPlanShape(
        dart_oracle.planTaskUpdate(current: task, title: 'Renamed'),
      ),
    );
    expect(nativeTask.value.sortOrder, lowSortOrder);
  });

  test('production ENEX parser uses the native codec including DOCTYPE', () {
    const source = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE en-export SYSTEM "http://xml.evernote.com/pub/evernote-export4.dtd">
<en-export><note><title>\uFEFF Shopping \uFEFF</title>
<content><![CDATA[<en-note><div>Milk</div><div>Eggs</div></en-note>]]></content>
<created>20230115T101500Z</created><tag>\uFEFFhome\uFEFF</tag>
<note-attributes><reminder-order>1</reminder-order></note-attributes>
<resource><data>AAAA</data></resource></note></en-export>''';
    final bundle = EnexParser.parse(source, notebookName: 'Evernote');

    expect(isRustCoreReady, isTrue);
    expect(bundle.notebookNames, ['Evernote']);
    expect(bundle.notes, hasLength(1));
    expect(bundle.notes.single.title, 'Shopping');
    expect(bundle.notes.single.content, 'Milk\nEggs');
    expect(bundle.notes.single.tagNames, ['home']);
    expect(bundle.notes.single.isPinned, isTrue);
    expect(bundle.notes.single.skippedAttachments, 1);
    expect(bundle.notes.single.createdAt, DateTime.utc(2023, 1, 15, 10, 15));
  });

  test('production EPUB exporter and importer round-trip through Rust', () {
    final now = DateTime.utc(2026, 7, 14, 12, 30);
    final bytes = EpubExporter.notesToEpub([
      Note(
        id: 'note-1',
        userId: 'user',
        title: 'First & Chapter',
        content: 'One paragraph.\n\nSecond <paragraph>.',
        createdAt: now,
        updatedAt: now,
      ),
      Note(
        id: 'note-2',
        userId: 'user',
        title: 'Emoji 😀',
        content: 'Body',
        createdAt: now,
        updatedAt: now,
      ),
    ], now: now);
    final bundle = EpubImporter.parse(bytes);

    expect(bytes, isNotEmpty);
    expect(bundle.notebookNames, ['Oblix export 2026-07-14']);
    expect(bundle.notes.map((note) => note.title), [
      'First & Chapter',
      'Emoji 😀',
    ]);
    expect(bundle.notes.first.content, contains('Second <paragraph>.'));
  });

  test('production Oblix v2 codec preserves hierarchy and attachments', () {
    final now = DateTime.utc(2026, 7, 14, 12, 30);
    final notebooks = [
      Notebook(
        id: 'root',
        userId: 'user',
        name: 'Work',
        createdAt: now,
        updatedAt: now,
      ),
      Notebook(
        id: 'child',
        userId: 'user',
        name: 'Projects',
        parentId: 'root',
        sortOrder: 2147483648,
        createdAt: now,
        updatedAt: now,
      ),
    ];
    final notes = [
      Note(
        id: 'note-1',
        userId: 'user',
        notebookId: 'child',
        title: 'Portable note',
        content: 'Body 😀',
        tagNames: const ['work'],
        createdAt: now,
        updatedAt: now,
      ),
    ];
    final tags = [
      Tag(
        id: 'tag-1',
        userId: 'user',
        name: 'work',
        createdAt: now,
        updatedAt: now,
      ),
    ];
    final bytes = OblixArchive.encode(
      notes: notes,
      notebooks: notebooks,
      tags: tags,
      attachmentsByNoteId: const {
        'note-1': [
          OblixAttachment(
            id: 'attachment-1',
            originalName: 'hello.TXT',
            mimeType: 'text/plain',
            bytes: [1, 2, 3, 4],
          ),
        ],
      },
    );
    final bundle = OblixArchive.decode(bytes);

    expect(bundle.notebookPaths, [
      ['Work'],
      ['Work', 'Projects'],
    ]);
    expect(bundle.notes.single.notebookPath, ['Work', 'Projects']);
    expect(bundle.notes.single.tagNames, ['work']);
    expect(bundle.notes.single.attachments.single.originalName, 'hello.TXT');
    expect(bundle.notes.single.attachments.single.bytes, [1, 2, 3, 4]);
    expect(() => OblixArchive.decode(const [1, 2, 3]), throwsFormatException);
  });

  test('Oblix timestamps retain Dart parsing, DST and fallback semantics', () {
    const offsetless = '2026-01-15T12:00:00';
    const compact = '20260713T120000Z';
    const overflowNormalized = '2026-01-42T00:00:00Z';
    final bytes = _oblixTimestampFixture([
      {'title': 'DST', 'created_at': offsetless, 'updated_at': compact},
      {
        'title': 'Overflow',
        'created_at': overflowNormalized,
        'updated_at': 'invalid',
      },
    ]);

    final bundle = OblixArchive.decode(bytes);
    final dst = bundle.notes[0];
    final overflow = bundle.notes[1];
    expect(dst.createdAt, DateTime.tryParse(offsetless)!.toUtc());
    expect(dst.updatedAt, DateTime.tryParse(compact)!.toUtc());
    expect(overflow.createdAt, DateTime.tryParse(overflowNormalized)!.toUtc());
    expect(overflow.updatedAt, overflow.createdAt);
  });

  test('Oblix round-trip supports Dart dates beyond Chrono range', () {
    final extreme = DateTime.utc(270000, 1, 1);
    final bytes = OblixArchive.encode(
      notes: [
        Note(
          id: 'extreme-date',
          userId: 'user',
          title: 'Far future',
          content: 'Still a valid Dart DateTime',
          createdAt: extreme,
          updatedAt: extreme,
        ),
      ],
      notebooks: const [],
      tags: const [],
    );

    final note = OblixArchive.decode(bytes).notes.single;
    expect(note.createdAt, extreme);
    expect(note.updatedAt, extreme);
  });
}
