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
}
