class ApiConfig {
  // Change this to your server's address
  // For Android emulator use 10.0.2.2, for iOS simulator use localhost
  static const String baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://10.0.2.2:8000',
  );

  static const String apiPrefix = '/api';

  static String get apiUrl => '$baseUrl$apiPrefix';

  // Timeouts
  static const Duration connectTimeout = Duration(seconds: 15);
  static const Duration receiveTimeout = Duration(seconds: 30);
  static const Duration sendTimeout = Duration(seconds: 30);

  // Sync
  static const Duration syncInterval = Duration(minutes: 5);
  static const int maxSyncBatchSize = 100;

  /// Quiet period after a local edit before pushing it (typing bursts
  /// coalesce into one sync; the backend docs assume ~30s cadence).
  static const Duration syncDebounceAfterEdit = Duration(seconds: 30);

  /// Pushes of an outbox entry the server never acknowledges before the entry
  /// is dropped as poison (so one bad change can't block the queue forever).
  static const int maxPushAttempts = 5;

  /// How long soft-deleted rows are kept locally after they've been synced,
  /// before being purged for good.
  static const Duration tombstoneRetention = Duration(days: 30);

  /// Backoff after consecutive sync failures: base * 2^failures, capped.
  static const Duration syncBackoffBase = Duration(minutes: 1);
  static const Duration syncBackoffMax = Duration(minutes: 30);
}
