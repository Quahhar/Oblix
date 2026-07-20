import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../core/app_bootstrap.dart';
import '../../core/auth/profile_cache.dart';
import '../../domain/services/import_export_service.dart';
import '../theme/oblix_theme.dart';
import '../theme/theme_controller.dart';
import '../util/formats.dart';
import '../widgets/paper.dart';
import 'archive_screen.dart';
import 'trash_screen.dart';

/// Profile card, preferences (appearance), data (import/export/trash), sync
/// status, and sign out.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _io = ImportExportService();
  bool _busy = false;

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _pickAppearance() async {
    final c = OblixColors.of(context);
    final choice = await showModalBottomSheet<ThemeMode>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SheetGrabHandle(),
            for (final mode in ThemeMode.values)
              ListTile(
                title: Text(
                  ThemeController.label(mode),
                  style: OblixType.ui(c, size: 15),
                ),
                trailing: ThemeController.instance.mode.value == mode
                    ? Icon(Icons.check, color: c.accent, size: 20)
                    : null,
                onTap: () => Navigator.pop(context, mode),
              ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
    if (choice != null) await ThemeController.instance.set(choice);
  }

  Future<void> _import() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['enex', 'oblix'],
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return;
    final file = picked.files.first;
    final bytes = file.bytes;
    if (bytes == null) {
      _snack('Could not read that file.');
      return;
    }
    setState(() => _busy = true);
    try {
      final ext = (file.extension ?? '').toLowerCase();
      final ImportResult result;
      if (ext == 'enex') {
        final base = file.name.replaceAll(
          RegExp(r'\.enex$', caseSensitive: false),
          '',
        );
        result = await _io.importEnex(
          utf8.decode(bytes),
          notebookName: base.isEmpty ? 'Imported' : base,
        );
      } else {
        result = await _io.importOblix(bytes);
      }
      _snack(
        'Imported ${result.notesImported} '
        '${result.notesImported == 1 ? 'note' : 'notes'}'
        '${result.notebooksCreated > 0 ? ', ${result.notebooksCreated} notebooks' : ''}',
      );
    } on FormatException catch (e) {
      _snack(e.message);
    } catch (e) {
      _snack('Import failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export() async {
    setState(() => _busy = true);
    try {
      final bytes = await _io.exportOblix();
      final dir = await getTemporaryDirectory();
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(RegExp(r'[:.]'), '-')
          .split('T')
          .first;
      final path = '${dir.path}/oblix-export-$stamp.oblix';
      await File(path).writeAsBytes(bytes, flush: true);
      if (!mounted) return;
      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile(
              path,
              mimeType: 'application/zip',
              name: 'oblix-export-$stamp.oblix',
            ),
          ],
          text: 'Oblix export',
        ),
      );
    } catch (e) {
      _snack('Export failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

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
      // always calls markSignedOut), so the AuthGate will route away.  Even if
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
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                  child: CircleIconButton(
                    Icons.arrow_back_ios_new,
                    size: 32,
                    onTap: () => Navigator.pop(context),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 16, 22, 0),
                  child: Text('Settings', style: OblixType.pageTitle(c)),
                ),
                // Profile
                PaperCard(
                  margin: const EdgeInsets.fromLTRB(22, 18, 22, 0),
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      ValueListenableBuilder<String?>(
                        valueListenable: ProfileCache.instance.name,
                        builder: (context, name, _) {
                          final initial = (name?.trim().isNotEmpty ?? false)
                              ? name!.trim()[0].toUpperCase()
                              : 'O';
                          return Container(
                            width: 52,
                            height: 52,
                            decoration: BoxDecoration(
                              color: c.accent,
                              shape: BoxShape.circle,
                            ),
                            child: Center(
                              child: Text(
                                initial,
                                style: OblixType.ui(
                                  c,
                                  size: 21,
                                  weight: FontWeight.w700,
                                  color: c.onAccent,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ValueListenableBuilder<String?>(
                              valueListenable: ProfileCache.instance.name,
                              builder: (context, name, _) => Text(
                                name ?? 'Your account',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: OblixType.ui(
                                  c,
                                  size: 16.5,
                                  weight: FontWeight.w600,
                                ),
                              ),
                            ),
                            ValueListenableBuilder<String?>(
                              valueListenable: ProfileCache.instance.email,
                              builder: (context, email, _) => Text(
                                email ?? '—',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: OblixType.ui(
                                  c,
                                  size: 12.5,
                                  color: c.inkMuted,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SectionEyebrow(
                  'Preferences',
                  padding: EdgeInsets.fromLTRB(26, 20, 26, 0),
                ),
                PaperCard(
                  margin: const EdgeInsets.fromLTRB(22, 10, 22, 0),
                  child: ValueListenableBuilder<ThemeMode>(
                    valueListenable: ThemeController.instance.mode,
                    builder: (context, mode, _) => _SettingsRow(
                      icon: Icons.dark_mode_outlined,
                      label: 'Appearance',
                      value: ThemeController.label(mode),
                      onTap: _pickAppearance,
                    ),
                  ),
                ),
                const SectionEyebrow(
                  'Your data',
                  padding: EdgeInsets.fromLTRB(26, 18, 26, 0),
                ),
                PaperCard(
                  margin: const EdgeInsets.fromLTRB(22, 10, 22, 0),
                  child: Column(
                    children: [
                      _SettingsRow(
                        icon: Icons.file_download_outlined,
                        label: 'Import notes',
                        value: '.enex · .oblix',
                        onTap: _busy ? null : _import,
                      ),
                      Divider(height: 1, color: c.hairline),
                      _SettingsRow(
                        icon: Icons.file_upload_outlined,
                        label: 'Export all notes',
                        value: '.oblix',
                        onTap: _busy ? null : _export,
                      ),
                      Divider(height: 1, color: c.hairline),
                      _SettingsRow(
                        icon: Icons.archive_outlined,
                        label: 'Archive',
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const ArchiveScreen(),
                          ),
                        ),
                      ),
                      Divider(height: 1, color: c.hairline),
                      _SettingsRow(
                        icon: Icons.delete_outline,
                        label: 'Trash',
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const TrashScreen(),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SectionEyebrow(
                  'Sync',
                  padding: EdgeInsets.fromLTRB(26, 18, 26, 0),
                ),
                PaperCard(
                  margin: const EdgeInsets.fromLTRB(22, 10, 22, 0),
                  child: ValueListenableBuilder<DateTime?>(
                    valueListenable: AppBootstrap.scheduler.lastSyncedAt,
                    builder: (context, at, _) => _SettingsRow(
                      icon: Icons.sync,
                      label: 'Sync now',
                      value: at == null ? 'Never' : Formats.relative(at),
                      onTap: () async {
                        final result = await AppBootstrap.scheduler.syncNow();
                        if (result.skipped) return;
                        _snack(
                          result.success
                              ? 'Synced — ${result.pushed} pushed, '
                                    '${result.pulled} pulled'
                              : 'Sync failed — changes are kept locally',
                        );
                      },
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(26, 22, 26, 0),
                  child: GestureDetector(
                    onTap: _busy ? null : _signOut,
                    child: Text(
                      'Sign out',
                      style: OblixType.ui(
                        c,
                        size: 14,
                        weight: FontWeight.w500,
                        color: c.danger,
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
      ),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? value;
  final VoidCallback? onTap;

  const _SettingsRow({
    required this.icon,
    required this.label,
    this.value,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Row(
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: c.surfaceAlt,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, size: 15, color: c.avatarInk),
            ),
            const SizedBox(width: 13),
            Expanded(child: Text(label, style: OblixType.ui(c, size: 14.5))),
            if (value != null)
              Text(value!, style: OblixType.ui(c, size: 13, color: c.inkMuted)),
            const SizedBox(width: 6),
            Icon(Icons.chevron_right, size: 16, color: c.outline),
          ],
        ),
      ),
    );
  }
}
