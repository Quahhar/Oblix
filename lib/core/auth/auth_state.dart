import 'package:flutter/foundation.dart';

enum AuthStatus { unknown, signedOut, signedIn }

/// App-wide session state. The auth repository flips it on login/logout, the
/// interceptor flips it when a token refresh fails, and both the UI (routing)
/// and the sync scheduler (start/stop) listen.
class AuthState {
  AuthState._();
  static final AuthState instance = AuthState._();

  final ValueNotifier<AuthStatus> status = ValueNotifier(AuthStatus.unknown);

  void markSignedIn() => status.value = AuthStatus.signedIn;

  /// The session is gone (explicit logout or failed refresh). Local data is
  /// deliberately NOT touched here — see AuthRepository for what gets cleared
  /// when.
  void markSignedOut() => status.value = AuthStatus.signedOut;
}
