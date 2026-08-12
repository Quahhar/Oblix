import 'package:uuid/uuid.dart';
import '../../core/db/app_database.dart';
import '../../core/db/meta_dao.dart';
import '../../core/time/sync_clock.dart';
import '../datasources/local/outbox_dao.dart';
import '../datasources/local/task_local_datasource.dart';
import '../models/sync_payload.dart';
import '../models/task.dart';
import '../models/crdt_clock.dart';
import '../../core/native/oblix_core.dart';

/// How far back the working set reaches for finished tasks. Only the recent
/// tail is ever rendered, and the completed pile grows without limit.
const Duration _completedWindow = Duration(days: 30);

/// Offline-first tasks — same contract as [NoteRepository]: every mutation
/// writes the local row AND its outbox entry in one transaction, reads come
/// from local SQLite, sync reconciles in the background (entity_type 'task').
///
/// Every scheduling decision — what a quick-add line means, where a repeating
/// task lands next, when a reminder fires — is delegated to the portable core.
/// This class owns identity, clocks, persistence and side effects, nothing
/// more.
class TaskRepository {
  final AppDatabase _appDb;
  final TaskLocalDataSource _local;
  final OutboxDao _outbox;
  final MetaDao _meta;
  final SyncClock _clock;
  final Uuid _uuid;

  TaskRepository({
    AppDatabase? appDb,
    TaskLocalDataSource? local,
    OutboxDao? outbox,
    MetaDao? meta,
    SyncClock? clock,
    Uuid? uuid,
  }) : _appDb = appDb ?? AppDatabase.instance,
       _local = local ?? TaskLocalDataSource(appDb ?? AppDatabase.instance),
       _outbox = outbox ?? OutboxDao(appDb ?? AppDatabase.instance),
       _meta = meta ?? MetaDao(appDb ?? AppDatabase.instance),
       _clock =
           clock ?? SyncClock(meta ?? MetaDao(appDb ?? AppDatabase.instance)),
       _uuid = uuid ?? const Uuid();

  /// Fires whenever local data changes, so callers can re-query.
  Stream<void> get onChanged => _appDb.onChanged;

  // --- Reads (local) ---

  /// [completed] tri-state: false = open, true = done, null = both.
  Future<List<Task>> listTasks({
    bool? completed = false,
    bool scheduledOnly = false,
    String? noteId,
    String? notebookId,
    String? parentId,
  }) {
    return _local.list(
      completed: completed,
      scheduledOnly: scheduledOnly,
      noteId: noteId,
      notebookId: notebookId,
      parentId: parentId,
    );
  }

  /// Everything the Tasks screen needs in one read; the core plans the rest.
  Future<List<Task>> loadWorkingSet({DateTime? now, String? notebookId}) {
    final reference = now ?? DateTime.now();
    return _local.loadWorkingSet(
      completedSince: reference.subtract(_completedWindow),
      notebookId: notebookId,
    );
  }

  Future<Task?> getTask(String taskId) => _local.getById(taskId);

  Future<int> countOpen() => _local.countOpen();

  Future<List<Task>> pendingReminders(DateTime from) =>
      _local.pendingReminders(from);

  // --- Quick add ---

  /// What a quick-add line would produce, without writing anything. The editor
  /// calls this on every keystroke to underline what it recognized.
  QuickAddParseValue previewQuickAdd(String text, {DateTime? now}) {
    final reference = (now ?? DateTime.now()).toLocal();
    return parseQuickAdd(text: text, context: _quickAddContext(reference));
  }

  /// Create a task from one typed line.
  ///
  /// [notebookId] and [parentId] are the surrounding context — the list the
  /// user is looking at, or the task they are adding a step to. A `#project`
  /// in the text overrides the former only once projects are resolvable by
  /// name; until then the typed name is kept as a label so nothing is lost.
  Future<Task> createFromQuickAdd(
    String text, {
    String? notebookId,
    String? parentId,
    String? noteId,
    DateTime? now,
  }) async {
    final reference = (now ?? DateTime.now()).toLocal();
    final parsed = parseQuickAdd(text: text, context: _quickAddContext(reference));
    final due = _resolveDue(parsed.due, parsed.dueTime);
    return createTask(
      title: parsed.title.isEmpty ? text.trim() : parsed.title,
      dueDate: due,
      dueHasTime: parsed.dueTime != null,
      priority: TaskPriority.fromValue(parsed.priority),
      // A typed #name has no id yet; keeping it as a label means the user's
      // intent survives instead of being silently dropped.
      labels: [
        ...parsed.labels,
        if (parsed.project != null) parsed.project!,
      ],
      recurrence: parsed.recurrence,
      reminderLeadMinutes: parsed.reminderLeadMinutes,
      notebookId: notebookId,
      parentId: parentId,
      noteId: noteId,
    );
  }

  // --- Writes (local + outbox, one transaction) ---

  Future<Task> createTask({
    required String title,
    String description = '',
    DateTime? dueDate,
    bool dueHasTime = false,
    TaskPriority priority = TaskPriority.none,
    List<String> labels = const [],
    String? recurrence,
    int? reminderLeadMinutes,
    DateTime? reminderAt,
    String? noteId,
    String? notebookId,
    String? parentId,
  }) async {
    final resolvedReminder =
        reminderAt ??
        _reminderFor(
          due: dueDate,
          dueHasTime: dueHasTime,
          leadMinutes: reminderLeadMinutes,
        );
    final plan = planTaskCreate(
      title: title,
      description: description,
      dueDateMicrosUtc: dueDate?.toUtc().microsecondsSinceEpoch,
      dueHasTime: dueHasTime,
      priority: priority.value,
      labels: labels,
      recurrence: recurrence,
      reminderAtMicrosUtc: resolvedReminder?.toUtc().microsecondsSinceEpoch,
      reminderLeadMinutes: reminderLeadMinutes,
      noteId: noteId,
      notebookId: notebookId,
      parentId: parentId,
    );
    final now = await _clock.nowUtc();
    final deviceId = await _meta.getOrCreateDeviceId();
    final fields = plan.selection.changedFields.toSet();
    final clocks = stampCrdtFields(const {}, fields, now, deviceId);
    final task = Task(
      id: _uuid.v4(), // client-minted, stable across sync
      userId: await _meta.getUserId() ?? '',
      noteId: plan.value.noteId,
      notebookId: plan.value.notebookId,
      parentId: plan.value.parentId,
      title: plan.value.title,
      description: plan.value.description,
      dueDate: _dateFromMicros(plan.value.dueDateMicrosUtc),
      dueHasTime: plan.value.dueHasTime,
      priority: TaskPriority.fromValue(plan.value.priority),
      labels: plan.value.labels,
      recurrence: plan.value.recurrence,
      reminderAt: _dateFromMicros(plan.value.reminderAtMicrosUtc),
      reminderLeadMinutes: plan.value.reminderLeadMinutes,
      sortOrder: plan.value.sortOrder,
      isCompleted: plan.value.isCompleted,
      completedAt: _dateFromMicros(plan.value.completedAtMicrosUtc),
      isDeleted: plan.value.isDeleted,
      createdAt: now,
      updatedAt: now,
      fieldClocks: clocks,
    );
    await _persist(task, 'create', fields, deviceId: deviceId);
    return task;
  }

  /// Nullable fields use sentinels internally: pass the matching `clear*` flag
  /// to detach, since a plain null means "unchanged".
  Future<Task> updateTask(
    String taskId, {
    String? title,
    String? description,
    DateTime? dueDate,
    bool clearDueDate = false,
    bool? dueHasTime,
    TaskPriority? priority,
    List<String>? labels,
    String? recurrence,
    bool clearRecurrence = false,
    int? reminderLeadMinutes,
    bool clearReminder = false,
    String? noteId,
    bool clearNoteId = false,
    String? notebookId,
    bool clearNotebookId = false,
    String? parentId,
    bool clearParentId = false,
    int? sortOrder,
  }) async {
    final existing = await _require(taskId);

    // A reminder is expressed as "N minutes before due", so moving the date or
    // the lead has to move the absolute time the notification fires at.
    final dueProvided = clearDueDate || dueDate != null;
    final nextDue = clearDueDate ? null : (dueDate ?? existing.dueDate);
    final nextHasTime = dueHasTime ?? existing.dueHasTime;
    final leadProvided = clearReminder || reminderLeadMinutes != null;
    final nextLead = clearReminder
        ? null
        : (reminderLeadMinutes ?? existing.reminderLeadMinutes);
    final reminderNeedsRecompute = dueProvided || leadProvided;
    final nextReminder = reminderNeedsRecompute
        ? _reminderFor(
            due: nextDue,
            dueHasTime: nextHasTime,
            leadMinutes: nextLead,
          )
        : null;

    final plan = planTaskUpdate(
      current: _taskMutationState(existing),
      title: title,
      description: description,
      dueDateProvided: dueProvided,
      dueDateMicrosUtc: clearDueDate
          ? null
          : dueDate?.toUtc().microsecondsSinceEpoch,
      dueHasTime: dueHasTime,
      priority: priority?.value,
      labels: labels,
      recurrenceProvided: clearRecurrence || recurrence != null,
      recurrence: clearRecurrence ? null : recurrence,
      reminderAtProvided: reminderNeedsRecompute,
      reminderAtMicrosUtc: nextReminder?.toUtc().microsecondsSinceEpoch,
      reminderLeadProvided: leadProvided,
      reminderLeadMinutes: nextLead,
      noteIdProvided: clearNoteId || noteId != null,
      noteId: clearNoteId ? null : noteId,
      notebookIdProvided: clearNotebookId || notebookId != null,
      notebookId: clearNotebookId ? null : notebookId,
      parentIdProvided: clearParentId || parentId != null,
      parentId: clearParentId ? null : parentId,
      sortOrder: sortOrder,
    );
    final fields = plan.selection.changedFields.toSet();
    if (fields.isEmpty) return existing;
    final now = await _clock.nextAfter(existing.updatedAt);
    final deviceId = await _meta.getOrCreateDeviceId();
    final updated = _applyPlan(existing, plan, now, deviceId, fields);
    await _persist(updated, 'update', fields, deviceId: deviceId);
    return updated;
  }

  /// Check / uncheck.
  ///
  /// A repeating task is not retired when it is ticked — it moves to its next
  /// occurrence, and its reminder moves with it. That is the whole point of a
  /// recurring chore, and getting it wrong is why "every Monday" in a weaker
  /// app quietly becomes a one-off.
  ///
  /// Completing a parent completes the subtasks under it: a step of a finished
  /// job is finished too, and leaving them open strands work nobody will look
  /// at again.
  Future<Task> setCompleted(String taskId, bool completed) async {
    final existing = await _require(taskId);

    if (completed && existing.repeats) {
      return _rollForward(existing);
    }

    final preliminary = planTaskCompletion(
      current: _taskMutationState(existing),
      completed: completed,
      timestampMicrosUtc: 0,
    );
    if (preliminary.selection.action == CoreMutationAction.noop) {
      return existing;
    }
    final now = await _clock.nextAfter(existing.updatedAt);
    final plan = planTaskCompletion(
      current: _taskMutationState(existing),
      completed: completed,
      timestampMicrosUtc: now.microsecondsSinceEpoch,
    );
    final deviceId = await _meta.getOrCreateDeviceId();
    final fields = plan.selection.changedFields.toSet();
    final toggled = _applyPlan(existing, plan, now, deviceId, fields);
    await _persist(toggled, 'update', fields, deviceId: deviceId);

    if (completed) await _completeChildren(taskId);
    return toggled;
  }

  /// Move a repeating task onto its next occurrence.
  Future<Task> _rollForward(Task task) async {
    final completedOn = civilDateOf(DateTime.now().toLocal());
    final advance = advanceOnCompletion(
      recurrence: task.recurrence,
      due: task.dueDate == null
          ? null
          : civilDateOf(task.dueDate!.toLocal()),
      dueHasTime: task.dueHasTime,
      completedOn: completedOn,
    );
    final nextDue = advance.nextDue;
    if (nextDue == null) {
      // The rule could not advance — treat it as an ordinary completion rather
      // than stranding the task on a date that never moved.
      return _completeOnce(task);
    }

    // Keep the time of day the occurrence was due at.
    final keptTime = advance.keepsTime && task.dueDate != null
        ? civilTimeOf(task.dueDate!.toLocal())
        : null;
    final nextDueUtc = localDateTimeOf(nextDue, keptTime).toUtc();
    final nextReminder = _reminderFor(
      due: nextDueUtc,
      dueHasTime: advance.keepsTime,
      leadMinutes: task.reminderLeadMinutes,
    );

    final plan = planTaskRollover(
      current: _taskMutationState(task),
      nextDueMicrosUtc: nextDueUtc.microsecondsSinceEpoch,
      nextReminderMicrosUtc: nextReminder?.toUtc().microsecondsSinceEpoch,
    );
    if (plan.selection.action == CoreMutationAction.noop) return task;

    final now = await _clock.nextAfter(task.updatedAt);
    final deviceId = await _meta.getOrCreateDeviceId();
    final fields = plan.selection.changedFields.toSet();
    final rolled = _applyPlan(task, plan, now, deviceId, fields);
    await _persist(rolled, 'update', fields, deviceId: deviceId);
    return rolled;
  }

  /// Completion without the repeating path, used when a rule cannot advance.
  Future<Task> _completeOnce(Task task) async {
    final now = await _clock.nextAfter(task.updatedAt);
    final plan = planTaskCompletion(
      current: _taskMutationState(task),
      completed: true,
      timestampMicrosUtc: now.microsecondsSinceEpoch,
    );
    if (plan.selection.action == CoreMutationAction.noop) return task;
    final deviceId = await _meta.getOrCreateDeviceId();
    final fields = plan.selection.changedFields.toSet();
    final done = _applyPlan(task, plan, now, deviceId, fields);
    await _persist(done, 'update', fields, deviceId: deviceId);
    return done;
  }

  Future<void> _completeChildren(String parentId) async {
    for (final child in await _local.childrenOf(parentId)) {
      if (!child.isCompleted) await setCompleted(child.id, true);
    }
  }

  /// Persist a manual reorder.
  ///
  /// The core returns only the rows whose rank actually moved, so dropping one
  /// task between two others writes one or two outbox entries instead of
  /// rewriting the list.
  Future<void> reorder(List<String> orderedIds) async {
    final current = await _local.sortOrdersFor(orderedIds);
    final changes = planReorder(
      orderedIds: orderedIds,
      current: [
        for (final entry in current.entries)
          (id: entry.key, sortOrder: entry.value),
      ],
    );
    for (final change in changes) {
      await updateTask(change.id, sortOrder: change.sortOrder);
    }
  }

  /// Soft-delete a task and everything nested under it. A subtask without its
  /// parent is orphaned work, so the whole branch goes together.
  Future<void> deleteTask(String taskId) async {
    final existing = await _local.getById(taskId);
    if (existing == null) return;
    for (final child in await _local.childrenOf(taskId)) {
      await deleteTask(child.id);
    }
    final plan = planTaskDelete(_taskMutationState(existing));
    final now = await _clock.nextAfter(existing.updatedAt);
    final deviceId = await _meta.getOrCreateDeviceId();
    final fields = plan.selection.changedFields.toSet();
    final deleted = _applyPlan(existing, plan, now, deviceId, fields);
    await _persist(deleted, 'delete', fields, deviceId: deviceId);
  }

  // --- Internals ---

  QuickAddContextValue _quickAddContext(DateTime reference) => (
    today: civilDateOf(reference),
    now: civilTimeOf(reference),
    // DateTime.weekday is 1 = Monday; the core counts from zero.
    todayWeekday: reference.weekday - 1,
    weekStartMonday: true,
    monthFirst: false,
  );

  /// Pin a parsed civil date (and optional wall time) to an instant. An
  /// all-day task lands at local midnight so reading it back yields the same
  /// civil date in the device's zone.
  DateTime? _resolveDue(CivilDateValue? date, CivilTimeValue? time) =>
      date == null ? null : localDateTimeOf(date, time).toUtc();

  /// The instant a reminder should fire, from the due date and the lead.
  DateTime? _reminderFor({
    required DateTime? due,
    required bool dueHasTime,
    required int? leadMinutes,
  }) {
    if (due == null || leadMinutes == null) return null;
    final local = due.toLocal();
    final fired = reminderTime(
      due: civilDateOf(local),
      dueTime: dueHasTime ? civilTimeOf(local) : null,
      leadMinutes: leadMinutes,
    );
    return fired == null
        ? null
        : localDateTimeOf(fired.date, fired.time).toUtc();
  }

  /// Fold a plan's value back onto the task and stamp the registers it moved.
  Task _applyPlan(
    Task existing,
    TaskMutationPlanValue plan,
    DateTime now,
    String deviceId,
    Set<String> fields,
  ) => existing.copyWith(
    title: plan.value.title,
    description: plan.value.description,
    noteId: plan.value.noteId,
    notebookId: plan.value.notebookId,
    parentId: plan.value.parentId,
    dueDate: _dateFromMicros(plan.value.dueDateMicrosUtc),
    dueHasTime: plan.value.dueHasTime,
    priority: TaskPriority.fromValue(plan.value.priority),
    labels: plan.value.labels,
    recurrence: plan.value.recurrence,
    reminderAt: _dateFromMicros(plan.value.reminderAtMicrosUtc),
    reminderLeadMinutes: plan.value.reminderLeadMinutes,
    sortOrder: plan.value.sortOrder,
    isCompleted: plan.value.isCompleted,
    completedAt: _dateFromMicros(plan.value.completedAtMicrosUtc),
    isDeleted: plan.value.isDeleted,
    updatedAt: now,
    fieldClocks: stampCrdtFields(existing.fieldClocks, fields, now, deviceId),
  );

  Future<Task> _require(String taskId) async {
    final existing = await _local.getById(taskId);
    if (existing == null) {
      throw StateError('Task $taskId not found locally');
    }
    return existing;
  }

  Future<void> _persist(
    Task task,
    String action,
    Set<String> fields, {
    required String deviceId,
  }) async {
    final data = task.toSyncPatch(fields);
    if (action == 'create') {
      data.addAll({
        'id': task.id,
        'user_id': task.userId,
        'created_at': task.createdAt.toUtc().toIso8601String(),
        'updated_at': task.updatedAt.toUtc().toIso8601String(),
      });
    }
    final change = SyncChangeItem(
      entityType: 'task',
      entityId: task.id,
      action: action,
      data: data,
      deviceId: deviceId,
      timestamp: task.updatedAt.toIso8601String(),
    );
    final db = await _appDb.database;
    await db.transaction((txn) async {
      await _local.upsert(txn, task);
      await _outbox.enqueue(txn, change);
    });
    _appDb.notifyChanged();
  }
}

TaskMutationStateValue _taskMutationState(Task task) => (
  title: task.title,
  description: task.description,
  noteId: task.noteId,
  notebookId: task.notebookId,
  parentId: task.parentId,
  dueDateMicrosUtc: task.dueDate?.toUtc().microsecondsSinceEpoch,
  dueHasTime: task.dueHasTime,
  priority: task.priority.value,
  labels: task.labels,
  recurrence: task.recurrence,
  reminderAtMicrosUtc: task.reminderAt?.toUtc().microsecondsSinceEpoch,
  reminderLeadMinutes: task.reminderLeadMinutes,
  sortOrder: task.sortOrder,
  isCompleted: task.isCompleted,
  completedAtMicrosUtc: task.completedAt?.toUtc().microsecondsSinceEpoch,
  isDeleted: task.isDeleted,
);

DateTime? _dateFromMicros(int? value) => value == null
    ? null
    : DateTime.fromMicrosecondsSinceEpoch(value, isUtc: true);
