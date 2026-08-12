import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import '../../core/auth/auth_state.dart';
import '../../core/config/api_config.dart';
import '../../core/db/app_database.dart';
import '../../core/db/meta_dao.dart';
import '../../data/datasources/local/outbox_dao.dart';
import '../../data/repositories/attachment_repository.dart';
import '../usecases/sync_notes.dart';
import '../../core/native/oblix_core.dart';

/// Fires the [SyncEngine] on the triggers that matter for an offline-first app:
///  - shortly after local edits (debounced, so typing bursts coalesce),
///  - a periodic timer (fallback / drains anything still queued),
///  - regained connectivity,
///  - app returning to the foreground.
///
/// [SyncEngine.syncOnce] already coalesces overlapping runs, so redundant
/// triggers are harmless. Consecutive failures back the timer off
/// exponentially (regained connectivity resets the backoff); a 401 that the
/// interceptor confirmed as a dead session stops the scheduler.
class SyncScheduler with WidgetsBindingObserver {
  final SyncEngine _engine;
  final AttachmentRepository _attachments;
  final AppDatabase _appDb;
  final OutboxDao _outbox;
  final MetaDao _meta;
  final Duration _interval;
  final Duration _editDebounceFor;

  /// When the last cycle succeeded — drives the Settings sync row. Restored
  /// from the meta table on [start] so it survives restarts.
  final ValueNotifier<DateTime?> lastSyncedAt = ValueNotifier(null);
  static const _kLastSyncedAt = 'last_synced_at';

  /// False from [start] until the session's first cycle has come back, either
  /// way it went.
  ///
  /// List screens read this to tell "you have nothing" apart from "your things
  /// have not arrived yet". Straight after a sign-in the local database is
  /// empty and the notes still live only on the server, so an empty-state
  /// screen would otherwise flash for as long as the first pull takes and read
  /// as a brand-new account. A failed first cycle settles it too: offline with
  /// an empty database, the emptiness is the honest answer.
  final ValueNotifier<bool> firstSyncSettled = ValueNotifier(false);

  Timer? _timer;
  Timer? _editDebounce;
  StreamSubscription<List<ConnectivityResult>>? _connSub;
  StreamSubscription<void>? _changeSub;
  bool _started = false;

  int _consecutiveFailures = 0;
  DateTime? _backoffUntil;

  SyncScheduler({
    SyncEngine? engine,
    AttachmentRepository? attachments,
    AppDatabase? appDb,
    OutboxDao? outbox,
    MetaDao? meta,
    Duration? interval,
    Duration? editDebounce,
  }) : _engine = engine ?? SyncEngine(),
       _attachments = attachments ?? AttachmentRepository(),
       _appDb = appDb ?? AppDatabase.instance,
       _outbox = outbox ?? OutboxDao(appDb ?? AppDatabase.instance),
       _meta = meta ?? MetaDao(appDb ?? AppDatabase.instance),
       _interval = interval ?? ApiConfig.syncInterval,
       _editDebounceFor = editDebounce ?? ApiConfig.syncDebounceAfterEdit;

  void start() {
    if (_started) return;
    _started = true;
    firstSyncSettled.value = false;

    unawaited(_restoreLastSynced());
    _timer = Timer.periodic(_interval, (_) => _trigger());

    _connSub = Connectivity().onConnectivityChanged.listen((results) {
      final online = results.any((r) => r != ConnectivityResult.none);
      if (online) {
        // Being back online invalidates the failure streak.
        _resetBackoff();
        _trigger();
      }
    });

    // Push soon after a local edit instead of waiting for the timer. The
    // change stream also fires for sync-applied changes, so the debounced
    // check is gated on the outbox actually holding something to push.
    _changeSub = _appDb.onChanged.listen((_) => _scheduleEditSync());

    WidgetsBinding.instance.addObserver(this);

    // Kick an initial sync on startup.
    _trigger();
  }

  void stop() {
    if (!_started) return;
    _started = false;
    // Nothing is going to arrive now, so release anything waiting on the first
    // cycle rather than leaving it on a spinner (a dead session stops us here
    // while the shell is still on screen for a frame or two).
    firstSyncSettled.value = true;
    _timer?.cancel();
    _timer = null;
    _editDebounce?.cancel();
    _editDebounce = null;
    _connSub?.cancel();
    _connSub = null;
    _changeSub?.cancel();
    _changeSub = null;
    WidgetsBinding.instance.removeObserver(this);
  }

  Future<void> _restoreLastSynced() async {
    final raw = await _meta.getSetting(_kLastSyncedAt);
    final parsed = DateTime.tryParse(raw ?? '');
    // A cycle that finished while we were loading wins over the stored value.
    if (parsed != null && lastSyncedAt.value == null) {
      lastSyncedAt.value = parsed.toLocal();
    }
  }

  void _scheduleEditSync() {
    _editDebounce?.cancel();
    _editDebounce = Timer(_editDebounceFor, () async {
      if (!_started) return;
      if (await _outbox.pendingCount() == 0) return; // nothing local to push
      _trigger();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _trigger();
  }

  /// Manually request a sync (e.g. pull-to-refresh, or right after login).
  /// Bypasses the failure backoff.
  Future<SyncResult> syncNow() async {
    final result = await _engine.syncOnce();
    _record(result);
    return result;
  }

  void _trigger() {
    final until = _backoffUntil;
    if (until != null && DateTime.now().isBefore(until)) return;
    // Fire and forget; failures are handled/retried inside the engine.
    unawaited(_engine.syncOnce().then(_record));
  }

  void _record(SyncResult result) {
    // A skipped result means a cycle was already in flight; that one reports
    // back, so the first sync is not settled by this call.
    if (result.skipped) return;
    firstSyncSettled.value = true;
    if (result.unauthorized &&
        AuthState.instance.status.value == AuthStatus.signedOut) {
      // Session is gone: the interceptor is the only thing that knows this — it
      // signs out when the server rejects the refresh token, and stays signed
      // in when the refresh merely failed to reach the server. Stop hammering
      // the API and let the UI route to login. Local data stays; see
      // AuthRepository. A 401 without that sign-out is a refresh we couldn't
      // complete (offline, 5xx), so it falls through to the normal backoff
      // instead of stranding the user on the login screen.
      stop();
      return;
    }
    if (result.success) {
      _resetBackoff();
      lastSyncedAt.value = DateTime.now();
      unawaited(
        _meta.setSetting(
          _kLastSyncedAt,
          lastSyncedAt.value!.toUtc().toIso8601String(),
        ),
      );
      // The note batch reached the server, so any attachment whose note just
      // synced is now uploadable. Best-effort and self-retrying; don't block.
      unawaited(_attachments.processSync());
      return;
    }
    _consecutiveFailures++;
    final backoffMs = syncBackoffMillis(
      consecutiveFailures: _consecutiveFailures,
      baseMillis: ApiConfig.syncBackoffBase.inMilliseconds,
      maxMillis: ApiConfig.syncBackoffMax.inMilliseconds,
    );
    _backoffUntil = DateTime.now().add(Duration(milliseconds: backoffMs));
  }

  void _resetBackoff() {
    _consecutiveFailures = 0;
    _backoffUntil = null;
  }
}
