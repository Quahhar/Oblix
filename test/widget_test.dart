// Widget tests for screens that don't need platform plugins.

import 'package:oblix/ui/screens/login_screen.dart';
import 'package:oblix/ui/theme/oblix_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Screens read their palette through `OblixColors.of(context)`, so they must
/// be pumped under the real theme (a bare MaterialApp has no extension).
Widget _app(Widget home, {ThemeMode mode = ThemeMode.light}) => MaterialApp(
  theme: OblixTheme.lightTheme,
  darkTheme: OblixTheme.darkTheme,
  themeMode: mode,
  home: home,
);

void main() {
  testWidgets('login screen renders and toggles to register mode', (
    tester,
  ) async {
    await tester.pumpWidget(_app(const LoginScreen()));

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
    await tester.pumpWidget(_app(const LoginScreen()));

    await tester.tap(find.text('Sign in'));
    await tester.pump();

    expect(find.text('Enter a valid email address'), findsOneWidget);
    expect(find.text('Enter a password'), findsOneWidget);
  });

  testWidgets('onboarding "Get started" lands on the register form', (
    tester,
  ) async {
    await tester.pumpWidget(_app(const LoginScreen(startInRegisterMode: true)));

    expect(find.text('Create account'), findsOneWidget);
    expect(find.text('Name'), findsOneWidget);
  });

  testWidgets('Classic light and dark themes carry the Oblix palette', (
    tester,
  ) async {
    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      late OblixColors colors;
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) {
              colors = OblixColors.of(
                context,
              ); // throws if the extension is absent
              return const SizedBox();
            },
          ),
          mode: mode,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        colors.accent,
        mode == ThemeMode.light
            ? const Color(0xFFE0AA12)
            : const Color(0xFFFFD60A),
      );
    }
  });

  testWidgets('Paper keeps the original warm palette', (tester) async {
    late OblixColors colors;
    await tester.pumpWidget(
      MaterialApp(
        theme: OblixTheme.paperLightTheme,
        home: Builder(
          builder: (context) {
            colors = OblixColors.of(context);
            return const SizedBox();
          },
        ),
      ),
    );

    expect(colors.bg, const Color(0xFFF0EEE6));
    expect(colors.accent, const Color(0xFFB0562F));
  });
}
