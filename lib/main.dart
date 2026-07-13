import 'package:flutter/material.dart';
import 'core/app_bootstrap.dart';
import 'ui/app.dart';

Future<void> main() async {
  // Initialize the offline-first logic layer (local DB, device id, background
  // sync) before the UI starts.
  await AppBootstrap.init();
  runApp(const OblixApp());
}
