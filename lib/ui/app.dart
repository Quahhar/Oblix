import 'package:flutter/material.dart';
import '../core/auth/auth_state.dart';
import 'screens/login_screen.dart';
import 'screens/notes_screen.dart';

class OblixApp extends StatelessWidget {
  const OblixApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Oblix',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: Brightness.dark,
        ),
      ),
      home: const AuthGate(),
    );
  }
}

/// Routes on session state: login screen while signed out, the notes app
/// while signed in. Reacts live — e.g. a failed token refresh during sync
/// flips [AuthState] and lands the user back on login.
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AuthStatus>(
      valueListenable: AuthState.instance.status,
      builder: (context, status, _) => switch (status) {
        AuthStatus.unknown =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
        AuthStatus.signedOut => const LoginScreen(),
        AuthStatus.signedIn => const NotesScreen(),
      },
    );
  }
}
