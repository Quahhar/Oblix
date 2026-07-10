// Widget tests for screens that don't need platform plugins.

import 'package:cyclux/ui/screens/login_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('login screen renders and toggles to register mode',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: LoginScreen()));

    expect(find.text('Sign in'), findsOneWidget);
    expect(find.text('Name'), findsNothing);

    await tester.tap(find.text('New here? Create an account'));
    await tester.pump();

    expect(find.text('Create account'), findsOneWidget);
    expect(find.text('Name'), findsOneWidget);

    await tester.tap(find.text('Already have an account? Sign in'));
    await tester.pump();
    expect(find.text('Sign in'), findsOneWidget);
  });

  testWidgets('login form validates before submitting', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: LoginScreen()));

    await tester.tap(find.text('Sign in'));
    await tester.pump();

    expect(find.text('Enter a valid email address'), findsOneWidget);
    expect(find.text('Enter a password'), findsOneWidget);
  });
}
