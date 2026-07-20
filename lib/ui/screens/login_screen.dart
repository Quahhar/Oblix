import 'package:flutter/material.dart';
import '../../core/network/api_exceptions.dart';
import '../../data/repositories/auth_repository.dart';
import '../theme/oblix_theme.dart';

/// Email/password sign-in with a register toggle. On success the repository
/// flips [AuthState] and the AuthGate swaps to the app — this widget never
/// navigates itself.
class LoginScreen extends StatefulWidget {
  const LoginScreen({
    super.key,
    this.auth,
    this.startInRegisterMode = false,
  });

  /// Injectable for widget tests.
  final AuthRepository? auth;

  /// Onboarding's "Get started" lands here on the register form.
  final bool startInRegisterMode;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  late final AuthRepository _auth = widget.auth ?? AuthRepository();

  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _displayName = TextEditingController();

  late bool _registerMode = widget.startInRegisterMode;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _displayName.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || !(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_registerMode) {
        await _auth.register(
          email: _email.text.trim(),
          password: _password.text,
          displayName: _displayName.text.trim(),
        );
      } else {
        await _auth.login(
          email: _email.text.trim(),
          password: _password.text,
        );
      }
      // AuthState is now signedIn; the AuthGate takes it from here.
    } on UnauthorizedException {
      setState(() => _error = 'Wrong email or password.');
    } on RateLimitedException catch (e) {
      final wait = e.retryAfter;
      setState(() => _error = wait == null
          ? 'Too many attempts. Please wait a moment and try again.'
          : 'Too many attempts. Try again in ${wait.inSeconds}s.');
    } on NetworkException {
      setState(() => _error = 'Cannot reach the server. Are you online?');
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = 'Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  InputDecoration _field(String label) {
    final c = OblixColors.of(context);
    return InputDecoration(
      labelText: label,
      labelStyle: OblixType.ui(c, size: 14, color: c.inkMuted),
      filled: true,
      fillColor: c.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: c.hairline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: c.accent, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: c.danger),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: c.danger, width: 1.5),
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: c.hairline),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text.rich(
                    TextSpan(
                      text: 'Oblix',
                      style: TextStyle(
                        fontFamily: OblixType.serif,
                        fontSize: 42,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.8,
                        color: c.ink,
                      ),
                      children: [
                        TextSpan(text: '.', style: TextStyle(color: c.accent)),
                      ],
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _registerMode
                        ? 'Create your account.'
                        : 'Your notes, everywhere. Even offline.',
                    textAlign: TextAlign.center,
                    style: OblixType.ui(c, size: 14.5, color: c.inkSecondary),
                  ),
                  const SizedBox(height: 32),
                  if (_registerMode) ...[
                    TextFormField(
                      controller: _displayName,
                      textInputAction: TextInputAction.next,
                      style: OblixType.ui(c, size: 15),
                      decoration: _field('Name'),
                      validator: (v) => (v == null || v.trim().isEmpty)
                          ? 'Enter your name'
                          : null,
                    ),
                    const SizedBox(height: 14),
                  ],
                  TextFormField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    textInputAction: TextInputAction.next,
                    style: OblixType.ui(c, size: 15),
                    decoration: _field('Email'),
                    validator: (v) {
                      final value = v?.trim() ?? '';
                      if (value.isEmpty || !value.contains('@')) {
                        return 'Enter a valid email address';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _password,
                    obscureText: true,
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: (_) => _submit(),
                    style: OblixType.ui(c, size: 15),
                    decoration: _field('Password'),
                    validator: (v) {
                      if (v == null || v.isEmpty) return 'Enter a password';
                      if (_registerMode && v.length < 8) {
                        return 'Use at least 8 characters';
                      }
                      return null;
                    },
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: OblixType.ui(c, size: 13.5, color: c.danger),
                    ),
                  ],
                  const SizedBox(height: 24),
                  Material(
                    color: _busy ? c.accent.withValues(alpha: 0.5) : c.accent,
                    shape: const StadiumBorder(),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: _busy ? null : _submit,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Center(
                          child: _busy
                              ? SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: c.onAccent),
                                )
                              : Text(
                                  _registerMode ? 'Create account' : 'Sign in',
                                  style: OblixType.ui(c,
                                      size: 15.5,
                                      weight: FontWeight.w600,
                                      color: c.onAccent),
                                ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                              _registerMode = !_registerMode;
                              _error = null;
                            }),
                    child: Text(
                      _registerMode
                          ? 'Already have an account? Sign in'
                          : 'New here? Create an account',
                      style: OblixType.ui(c,
                          size: 14,
                          weight: FontWeight.w500,
                          color: c.inkSecondary),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
