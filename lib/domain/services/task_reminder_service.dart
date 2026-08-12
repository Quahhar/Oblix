import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../../data/models/task.dart';
import '../../data/repositories/task_repository.dart';

/// Reminders that actually fire.
///
/// The previous Tasks screen had a "Remind me" section that set a due date and
/// notified nobody, which is the single most common reason someone keeps a
/// second task app installed. This schedules real local notifications and, just
/// as importantly, keeps them honest: the whole pending set is re-derived from
/// the database whenever anything changes, so a rescheduled task moves its
/// alarm and a completed one loses it.
///
/// Reminders are local-only by design. The server holds `reminder_at` so it
/// syncs across devices, but every device schedules its own alarms from its own
/// clock and zone — there is no push infrastructure and a reminder must work in
/// airplane mode.
class TaskReminderService {
  TaskReminderService({TaskRepository? tasks, FlutterLocalNotificationsPlugin? plugin})
    : _tasks = tasks ?? TaskRepository(),
      _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  static final TaskReminderService instance = TaskReminderService();

  /// Android channel. Changing the id after release creates a *new* channel and
  /// silently abandons the user's sound and importance choices, so it is
  /// deliberately boring and permanent.
  static const _channelId = 'oblix_task_reminders';
  static const _channelName = 'Task reminders';
  static const _channelDescription = 'Alerts for tasks that are coming due.';

  /// Notification action that completes a task from the shade.
  static const completeActionId = 'oblix_task_complete';

  /// Whether to ask Android for to-the-minute delivery.
  ///
  /// Left off: exact alarms require declaring `SCHEDULE_EXACT_ALARM` usage to
  /// the Play Store, and a reminder that lands a few minutes late under Doze is
  /// a far smaller cost than a rejected release. Flip this to
  /// `AndroidScheduleMode.exactAllowWhileIdle` and add the permission to the
  /// manifest if that trade ever changes.
  static const _scheduleMode = AndroidScheduleMode.inexactAllowWhileIdle;

  /// Android caps how many alarms one app may hold, so the horizon is bounded
  /// and refilled on every change rather than scheduled once forever.
  static const _maxScheduled = 60;

  final TaskRepository _tasks;
  final FlutterLocalNotificationsPlugin _plugin;

  StreamSubscription<void>? _changes;
  bool _ready = false;

  /// Prepare the plugin and arm everything currently pending.
  ///
  /// Safe to call when notifications are unavailable or refused: failures are
  /// contained here, because a device that cannot notify must still be able to
  /// keep tasks.
  Future<void> init() async {
    if (_ready) return;
    try {
      tz_data.initializeTimeZones();
      tz.setLocalLocation(tz.getLocation(await FlutterTimezone.getLocalTimezone()));

      await _plugin.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(
            // Asked for explicitly in [requestPermission] instead, so the
            // prompt appears when the user first sets a reminder rather than
            // on first launch.
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
        ),
        onDidReceiveNotificationResponse: _onResponse,
        onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
      );

      await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.createNotificationChannel(
            const AndroidNotificationChannel(
              _channelId,
              _channelName,
              description: _channelDescription,
              importance: Importance.high,
            ),
          );

      _ready = true;
      _changes = _tasks.onChanged.listen((_) => unawaited(refresh()));
      await refresh();
    } on Object catch (error, stack) {
      // A missing plugin, a denied channel, an unknown zone: none of these are
      // worth failing app startup over.
      debugPrint('Task reminders unavailable: $error\n$stack');
    }
  }

  Future<void> dispose() async {
    await _changes?.cancel();
    _changes = null;
  }

  /// Ask for permission at the moment the user first wants a reminder.
  /// Returns false when the platform refuses or has no notion of permission.
  Future<bool> requestPermission() async {
    if (!_ready) await init();
    if (!_ready) return false;
    try {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      if (android != null) {
        return await android.requestNotificationsPermission() ?? false;
      }
      final ios = _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >();
      if (ios != null) {
        return await ios.requestPermissions(alert: true, badge: true, sound: true) ??
            false;
      }
    } on Object catch (error) {
      debugPrint('Notification permission request failed: $error');
    }
    return false;
  }

  /// Re-derive every pending alarm from the database.
  ///
  /// Cancelling and rescheduling the whole set is deliberate. Diffing would
  /// mean tracking which alarm belongs to which version of which task across
  /// sync merges and reboots; re-deriving is a handful of rows and cannot go
  /// stale.
  Future<void> refresh() async {
    if (!_ready) return;
    try {
      final now = DateTime.now();
      final pending = await _tasks.pendingReminders(now);
      await _plugin.cancelAll();
      for (final task in pending.take(_maxScheduled)) {
        await _schedule(task);
      }
    } on Object catch (error, stack) {
      debugPrint('Rescheduling reminders failed: $error\n$stack');
    }
  }

  Future<void> _schedule(Task task) async {
    final fireAt = task.reminderAt?.toLocal();
    if (fireAt == null || !fireAt.isAfter(DateTime.now())) return;

    await _plugin.zonedSchedule(
      _notificationId(task.id),
      task.title,
      _subtitle(task),
      tz.TZDateTime.from(fireAt, tz.local),
      NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDescription,
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.reminder,
          actions: const [
            AndroidNotificationAction(
              completeActionId,
              'Done',
              showsUserInterface: false,
              cancelNotification: true,
            ),
          ],
        ),
        iOS: const DarwinNotificationDetails(
          categoryIdentifier: _channelId,
          interruptionLevel: InterruptionLevel.timeSensitive,
        ),
      ),
      androidScheduleMode: _scheduleMode,
      payload: task.id,
    );
  }

  /// What the reminder says under the title: when it is due, and how much it
  /// matters. Kept short — a notification is read in a glance.
  static String? _subtitle(Task task) {
    final parts = <String>[
      if (task.priority == TaskPriority.urgent) 'Urgent',
      if (task.dueDate != null && task.dueHasTime)
        _clock(task.dueDate!.toLocal())
      else if (task.dueDate != null)
        'Due today',
      if (task.description.isNotEmpty) task.description,
    ];
    if (parts.isEmpty) return null;
    return parts.join(' · ');
  }

  static String _clock(DateTime local) {
    final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
    final minute = local.minute.toString().padLeft(2, '0');
    return '$hour:$minute ${local.hour >= 12 ? 'PM' : 'AM'}';
  }

  /// A stable 31-bit id derived from the task's UUID.
  ///
  /// The platform keys alarms by int, so the same task must always map to the
  /// same slot — otherwise rescheduling leaves the old alarm armed and the user
  /// is reminded twice.
  static int _notificationId(String taskId) => taskId.hashCode & 0x7fffffff;

  Future<void> _onResponse(NotificationResponse response) async {
    final taskId = response.payload;
    if (taskId == null) return;
    if (response.actionId == completeActionId) {
      try {
        await _tasks.setCompleted(taskId, true);
      } on StateError {
        // Deleted on another device before the notification was acted on.
      }
    }
  }
}

/// Runs in a background isolate when an action is used while the app is not in
/// the foreground. It deliberately does no work: the isolate has no database
/// handle, and the alarm is re-derived from SQLite the next time the app opens.
@pragma('vm:entry-point')
void notificationTapBackground(NotificationResponse response) {}
