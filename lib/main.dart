import 'package:flutter/material.dart';
import 'core/app_bootstrap.dart';
import 'core/config/api_config.dart';
import 'ui/app.dart';

Future<void> main() async {
  // Temporary diagnostic: confirm which backend this build talks to.
  debugPrint('API URL: ${ApiConfig.apiUrl}');
  // Initialize the offline-first logic layer (local DB, device id, background
  // sync) before the UI starts.
  await AppBootstrap.init();
  runApp(const OblixApp());
}
