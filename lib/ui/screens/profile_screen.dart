import 'package:flutter/material.dart';

import '../../core/app_bootstrap.dart';
import '../../core/auth/profile_cache.dart';
import '../theme/oblix_theme.dart';
import '../widgets/paper.dart';
import 'settings_screen.dart';
import 'shared_with_me_screen.dart';

/// Who you are signed in as: identity, collaboration, and the session itself.
///
/// This is a shell tab rather than a pushed route, so the navigation dock stays
/// put while you are here. Anything that configures the app rather than the
/// account lives in [SettingsScreen], which is pushed over the dock.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  bool _busy = false;

  Future<void> _signOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text(
          'Unsynced changes are pushed first if possible. Local data on this '
          'device is then removed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (!(confirmed ?? false)) return;
    setState(() => _busy = true);
    try {
      await AppBootstrap.signOut();
    } catch (_) {
      // Best-effort logout still flips AuthState to signedOut (the repository
      // always calls markSignedOut), so the AuthGate will route away. Even if
      // local cleanup threw, the user is signed out.
    } finally {
      ProfileCache.instance.clear();
      if (mounted) setState(() => _busy = false);
    }
    // AuthGate routes back to login on the state flip; nothing else to do.
  }

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    return SafeArea(
      bottom: false,
      child: Stack(
        children: [
          ListView(
            // Clears the floating dock, which this screen keeps.
            padding: const EdgeInsets.only(bottom: 116),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                child: Text('ACCOUNT', style: OblixType.eyebrow(c)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
                child: Text('Profile', style: OblixType.pageTitle(c)),
              ),
              PaperCard(
                margin: const EdgeInsets.fromLTRB(20, 18, 20, 0),
                padding: const EdgeInsets.all(18),
                child: Column(
                  children: [
                    ValueListenableBuilder<String?>(
                      valueListenable: ProfileCache.instance.name,
                      builder: (context, name, _) =>
                          OblixAvatar(name: name, size: 74),
                    ),
                    const SizedBox(height: 14),
                    ValueListenableBuilder<String?>(
                      valueListenable: ProfileCache.instance.name,
                      builder: (context, name, _) => Text(
                        name ?? 'Your account',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: OblixType.serif,
                          fontSize: 22,
                          fontWeight: FontWeight.w600,
                          color: c.ink,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    ValueListenableBuilder<String?>(
                      valueListenable: ProfileCache.instance.email,
                      builder: (context, email, _) => Text(
                        email ?? 'Signed in',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: OblixType.ui(c, size: 13.5, color: c.inkMuted),
                      ),
                    ),
                  ],
                ),
              ),
              const SectionEyebrow(
                'Collaboration',
                padding: EdgeInsets.fromLTRB(26, 22, 26, 0),
              ),
              PaperCard(
                margin: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                child: SettingsRow(
                  icon: Icons.group_outlined,
                  label: 'Shared with me',
                  value: 'Notes others invited you to',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const SharedWithMeScreen(),
                    ),
                  ),
                ),
              ),
              const SectionEyebrow(
                'App',
                padding: EdgeInsets.fromLTRB(26, 18, 26, 0),
              ),
              PaperCard(
                margin: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                child: SettingsRow(
                  icon: Icons.tune,
                  label: 'Settings',
                  value: 'Appearance, data, sync',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const SettingsScreen()),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
                child: Center(
                  child: GlassPill(
                    onTap: _busy ? null : _signOut,
                    borderColor: c.danger,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 10,
                    ),
                    child: Text(
                      'Sign out',
                      style: OblixType.ui(
                        c,
                        size: 14,
                        weight: FontWeight.w600,
                        color: c.danger,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (_busy)
            Positioned.fill(
              child: ColoredBox(
                color: c.scrim.withValues(alpha: 0.2),
                child: const Center(child: CircularProgressIndicator()),
              ),
            ),
        ],
      ),
    );
  }
}
