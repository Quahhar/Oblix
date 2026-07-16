import 'dart:async';
import 'dart:math' as math;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import '../../core/auth/auth_state.dart';
import '../../core/config/api_config.dart';
import '../../data/repositories/attachment_repository.dart';
import '../usecases/sync_notes.dart';

/// Fires the [SyncEngine] on the triggers that matter for an offline-first app:
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
  final Duration _interval;

  Timer? _timer;
  StreamSubscription<List<ConnectivityResult>>? _connSub;
  bool _started = false;

  int _consecutiveFailures = 0;
  DateTime? _backoffUntil;

  SyncScheduler({
    SyncEngine? engine,
    AttachmentRepository? attachments,
    Duration? interval,
  })  : _engine = engine ?? SyncEngine(),
        _attachments = attachments ?? AttachmentRepository(),
        _interval = interval ?? ApiConfig.syncInterval;

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

    WidgetsBinding.instance.addObserver(this);

    // Kick an initial sync on startup.
    _trigger();
  }

  void stop() {
    if (!_started) return;
    _started = false;
    _timer?.cancel();
    _timer = null;
    _connSub?.cancel();
    _connSub = null;
    WidgetsBinding.instance.removeObserver(this);
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
