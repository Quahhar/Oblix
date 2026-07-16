import 'dart:async';
import 'dart:math' as math;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import '../../core/auth/auth_state.dart';
import '../../core/config/api_config.dart';
import '../../core/db/app_database.dart';
import '../../data/datasources/local/outbox_dao.dart';
import '../../data/repositories/attachment_repository.dart';
import '../usecases/sync_notes.dart';

/// Fires the [SyncEngine] on the triggers that matter for an offline-first app:
///  - shortly after local edits (debounced, so typing bursts coalesce),
///  - a periodic timer (fallback / drains anything still queued),
///  - regained connectivity,
///  - app returning to the foreground.
///
/// [SyncEngine.syncOnce] already coalesces overlapping runs, so redundant
/// triggers are harmless. Consecutive failures back the timer off
/// exponentially (regained connectivity resets the backoff); an unauthorized
/// response stops the scheduler and flips the app-wide auth state.
class SyncScheduler with WidgetsBindingObserver {
  final SyncEngine _engine;
  final AttachmentRepository _attachments;
  final AppDatabase _appDb;
  final OutboxDao _outbox;
  final Duration _interval;
  final Duration _editDebounceFor;

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
    Duration? interval,
    Duration? editDebounce,
  })  : _engine = engine ?? SyncEngine(),
        _attachments = attachments ?? AttachmentRepository(),
        _appDb = appDb ?? AppDatabase.instance,
        _outbox = outbox ?? OutboxDao(appDb ?? AppDatabase.instance),
        _interval = interval ?? ApiConfig.syncInterval,
        _editDebounceFor = editDebounce ?? ApiConfig.syncDebounceAfterEdit;

  void start() {
    if (_started) return;
    _started = true;

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
    if (result.skipped) return;
    if (result.unauthorized) {
      // Session is gone (refresh failed too). Stop hammering the API and let
      // the UI route to login. Local data stays; see AuthRepository.
      stop();
      AuthState.instance.markSignedOut();
      return;
    }
    if (result.success) {
      _resetBackoff();
      // The note batch reached the server, so any attachment whose note just
      // synced is now uploadable. Best-effort and self-retrying; don't block.
      unawaited(_attachments.processSync());
      return;
    }
    _consecutiveFailures++;
    final backoffMs = math.min(
      ApiConfig.syncBackoffBase.inMilliseconds <<
          math.min(_consecutiveFailures - 1, 10),
      ApiConfig.syncBackoffMax.inMilliseconds,
    );
    _backoffUntil = DateTime.now().add(Duration(milliseconds: backoffMs));
  }

  void _resetBackoff() {
    _consecutiveFailures = 0;
    _backoffUntil = null;
  }
}
