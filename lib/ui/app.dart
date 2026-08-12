import 'package:flutter/material.dart';
import '../core/auth/auth_state.dart';
import 'screens/login_screen.dart';
import 'screens/onboarding_screen.dart';
import 'shell/home_shell.dart';
import 'theme/oblix_theme.dart';
import 'theme/theme_controller.dart';

class OblixApp extends StatelessWidget {
  const OblixApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeController.instance.mode,
      builder: (context, mode, _) =>
          ValueListenableBuilder<OblixThemeCollection>(
            valueListenable: ThemeController.instance.collection,
            builder: (context, collection, _) => MaterialApp(
              title: 'Oblix',
              debugShowCheckedModeBanner: false,
              theme: OblixTheme.forCollection(collection, Brightness.light),
              darkTheme: OblixTheme.forCollection(collection, Brightness.dark),
              themeMode: mode,
              // Every Liquid Glass control blurs through BackdropFilter.grouped,
              // so this one group lets a screenful of them share a single
              // backdrop read instead of paying for one each — the difference
              // between smooth and janky on a mid-range phone.
              builder: (context, child) =>
                  BackdropGroup(child: child ?? const SizedBox.shrink()),
              home: const AuthGate(),
            ),
          ),
    );
  }
}

/// Routes on session state: the app while signed in; onboarding-then-login on
/// a fresh install, login alone afterwards. Reacts live — e.g. a failed token
/// refresh during sync flips [AuthState] and lands the user back on login.
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AuthStatus>(
      valueListenable: AuthState.instance.status,
      builder: (context, status, _) => switch (status) {
        AuthStatus.unknown => const Scaffold(
          body: Center(child: CircularProgressIndicator()),
        ),
        AuthStatus.signedOut => const _SignedOutGate(),
        AuthStatus.signedIn => const HomeShell(),
      },
    );
  }
}

/// Onboarding runs once per install, before the first sign-in.
///
/// Both children are rendered in place rather than pushed as routes: they live
/// inside the [AuthGate] subtree, so signing in swaps the whole thing for the
/// app. A pushed login form would outlive the gate and leave the user staring
/// at it after a successful sign-in.
class _SignedOutGate extends StatefulWidget {
  const _SignedOutGate();

  @override
  State<_SignedOutGate> createState() => _SignedOutGateState();
}

class _SignedOutGateState extends State<_SignedOutGate> {
  /// Resolved once — rebuilding the gate must not restart the lookup and
  /// bounce the user back to the walkthrough.
  late final Future<bool> _seenOnboarding = OnboardingScreen.hasSeen();

  /// Set when onboarding finishes in this session; carries whether to open on
  /// the register form.
  bool? _startInRegisterMode;

  @override
  Widget build(BuildContext context) {
    final startInRegisterMode = _startInRegisterMode;
    if (startInRegisterMode != null) {
      return LoginScreen(startInRegisterMode: startInRegisterMode);
    }
    return FutureBuilder<bool>(
      future: _seenOnboarding,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Scaffold(body: SizedBox.shrink());
        }
        if (snapshot.data!) return const LoginScreen();
        return OnboardingScreen(
          onFinished: ({required bool register}) =>
              setState(() => _startInRegisterMode = register),
        );
      },
    );
  }
}
