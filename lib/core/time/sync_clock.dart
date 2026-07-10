import '../db/meta_dao.dart';

/// Wall clock corrected by the skew observed against the server at the last
/// sync. Local mutations timestamp with this so a device with a wrong clock
/// neither loses every last-write-wins merge nor unfairly wins them all.
class SyncClock {
  final MetaDao _meta;
  SyncClock(this._meta);

  Future<DateTime> nowUtc() async =>
      DateTime.now().toUtc().add(await _meta.getClockSkew());

  /// A skew-corrected timestamp guaranteed to be after [previous], so an edit
  /// can never be timestamped at-or-before the version it modifies (which
  /// would make it lose LWW against its own past, e.g. when the clock is set
  /// backwards between edits).
  Future<DateTime> nextAfter(DateTime? previous) async {
    final now = await nowUtc();
    if (previous != null && !now.isAfter(previous)) {
      return previous.add(const Duration(milliseconds: 1));
    }
    return now;
  }
}
