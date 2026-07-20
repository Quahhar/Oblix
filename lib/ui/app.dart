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
      builder: (context, mode, _) => MaterialApp(
        title: 'Oblix',
        debugShowCheckedModeBanner: false,
        theme: OblixTheme.lightTheme,
        darkTheme: OblixTheme.darkTheme,
        themeMode: mode,
        home: const AuthGate(),
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
        AuthStatus.unknown =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
        AuthStatus.signedOut => const _SignedOutGate(),
        AuthStatus.signedIn => const HomeShell(),
      },
    );
  }
}

/// Onboarding runs once per install, before the first sign-in.
class _SignedOutGate extends StatelessWidget {
  const _SignedOutGate();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: OnboardingScreen.hasSeen(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Scaffold(body: SizedBox.shrink());
        }
        return snapshot.data! ? const LoginScreen() : const OnboardingScreen();
      },
    );
  }
}
