import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import '../../core/config/api_config.dart';
import '../usecases/sync_notes.dart';

/// Fires the [SyncEngine] on the triggers that matter for an offline-first app:
///  - a periodic timer (fallback / drains anything still queued),
///  - regained connectivity,
///  - app returning to the foreground.
///
/// [SyncEngine.syncOnce] already coalesces overlapping runs, so redundant
/// triggers are harmless.
class SyncScheduler with WidgetsBindingObserver {
  final SyncEngine _engine;
  final Duration _interval;

  Timer? _timer;
  StreamSubscription<List<ConnectivityResult>>? _connSub;
  bool _started = false;

  SyncScheduler({SyncEngine? engine, Duration? interval})
      : _engine = engine ?? SyncEngine(),
        _interval = interval ?? ApiConfig.syncInterval;

  void start() {
    if (_started) return;
    _started = true;

    _timer = Timer.periodic(_interval, (_) => _trigger());

    _connSub = Connectivity().onConnectivityChanged.listen((results) {
      final online = results.any((r) => r != ConnectivityResult.none);
      if (online) _trigger();
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
  Future<SyncResult> syncNow() => _engine.syncOnce();

  void _trigger() {
    // Fire and forget; failures are handled/retried inside the engine.
    unawaited(_engine.syncOnce());
  }
}
