import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/app_bootstrap.dart';
import '../../data/models/note.dart';
import '../../domain/services/import_export_service.dart';
import '../theme/oblix_theme.dart';
import '../theme/theme_controller.dart';
import '../util/formats.dart';
import '../widgets/paper.dart';
import 'archive_screen.dart';
import 'trash_screen.dart';

/// How the app behaves: appearance, your data (import/export/archive/trash),
/// and sync.
///
/// Deliberately holds nothing about *who* is signed in — identity, sharing, and
/// sign-out belong to the Profile tab. This screen is pushed as a route, so it
/// covers the navigation dock; Profile does not.
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

  Future<void> _pickThemeCollection() async {
    final c = OblixColors.of(context);
    final choice = await showModalBottomSheet<OblixThemeCollection>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SheetGrabHandle(),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 4, 22, 10),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Theme collection', style: OblixType.cardTitle(c)),
              ),
            ),
            for (final collection in OblixThemeCollection.values)
              ListTile(
                leading: _ThemeSwatch(collection: collection),
                title: Text(collection.label, style: OblixType.ui(c, size: 15)),
                subtitle: Text(
                  collection.description,
                  style: OblixType.ui(c, size: 12.5, color: c.inkMuted),
                ),
                trailing:
                    ThemeController.instance.collection.value == collection
                    ? Icon(Icons.check, color: c.accent, size: 20)
                    : null,
                onTap: () => Navigator.pop(context, collection),
              ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
    if (choice != null) {
      await ThemeController.instance.setCollection(choice);
    }
  }

  // --- Import ---

  Future<void> _import() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['enex', 'oblix', 'md', 'txt', 'epub'],
      allowMultiple: true,
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return;

    setState(() => _busy = true);
    try {
      ImportResult result = ImportResult.empty;
      var filesSucceeded = 0;
      final failures = <({String name, String reason})>[];
      for (final file in picked.files) {
        final bytes = file.bytes;
        if (bytes == null) {
          failures.add((name: file.name, reason: 'Could not read file'));
          continue;
        }
        final ext = (file.extension ?? '').toLowerCase();

        try {
          final ImportResult fileResult;
          switch (ext) {
            case 'enex':
              final base = file.name.replaceAll(
                RegExp(r'\.enex$', caseSensitive: false),
                '',
              );
              fileResult = await _io.importEnex(
                utf8.decode(bytes),
                notebookName: base.isEmpty ? 'Imported' : base,
              );
            case 'oblix':
              fileResult = await _io.importOblix(bytes);
            case 'md':
            case 'txt':
              // Apply each text file independently so one unread/malformed
              // selection cannot hide or roll back the files that succeeded.
              fileResult = await _io.importMarkdownFiles([(file.name, bytes)]);
            case 'epub':
              fileResult = await _io.importEpub(bytes);
            default:
              throw const FormatException('Unsupported import format');
          }
          result += fileResult;
          filesSucceeded++;
        } on FormatException catch (error) {
          failures.add((name: file.name, reason: error.message));
        } catch (_) {
          failures.add((name: file.name, reason: 'Import failed'));
        }
      }

      await _showImportOutcome(
        result,
        filesSucceeded: filesSucceeded,
        failures: failures,
      );
    } catch (e) {
      _snack('Import failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showImportOutcome(
    ImportResult result, {
    required int filesSucceeded,
    required List<({String name, String reason})> failures,
  }) async {
    final skipped = result.skippedAttachments;
    final summary =
        '$filesSucceeded ${filesSucceeded == 1 ? 'file' : 'files'} succeeded · '
        '${result.notesImported} '
        '${result.notesImported == 1 ? 'note' : 'notes'} imported'
        '${result.notebooksCreated > 0 ? ' · ${result.notebooksCreated} notebooks created' : ''}'
        '${skipped > 0 ? ' · $skipped ${skipped == 1 ? 'attachment' : 'attachments'} skipped' : ''}';

    if (failures.isEmpty && skipped == 0) {
      _snack(summary);
      return;
    }
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          failures.isEmpty
              ? 'Import completed with skipped attachments'
              : 'Import completed with issues',
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(summary),
              if (failures.isNotEmpty) ...[
                const SizedBox(height: 14),
                Text(
                  '${failures.length} '
                  '${failures.length == 1 ? 'file' : 'files'} failed:',
                ),
                const SizedBox(height: 6),
                for (final failure in failures)
                  Text('• ${failure.name}: ${failure.reason}'),
              ],
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  // --- Export ---

  Future<void> _export() async {
    final c = OblixColors.of(context);
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SheetGrabHandle(),
            _exportOption(
              'oblix',
              'Portable Oblix notes (.oblix)',
              Icons.archive_outlined,
              c,
            ),
            _exportOption(
              'epub',
              'EPUB ebook (.epub)',
              Icons.menu_book_outlined,
              c,
            ),
            _exportOption('md', 'Markdown (.zip)', Icons.code, c),
            _exportOption(
              'txt',
              'Plain text (.zip)',
              Icons.description_outlined,
              c,
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
    if (choice == null) return;

    final available = await _io.listExportableNotes();
    if (!mounted) return;
    if (available.isEmpty) {
      _snack('There are no notes to export.');
      return;
    }
    final selected = await _pickNotesForExport(available);
    if (selected == null || selected.isEmpty || !mounted) return;

    setState(() => _busy = true);
    try {
      // The picker can stay open while background sync updates or deletes a
      // note. Resolve the chosen ids again at the serialization boundary so
      // the exported snapshot is current and never includes a deleted row.
      final currentById = {
        for (final note in await _io.listExportableNotes()) note.id: note,
      };
      final refreshed = <Note>[];
      for (final selectedNote in selected) {
        final current = currentById[selectedNote.id];
        if (current == null) {
          _snack(
            'A selected note is no longer available. Review your selection '
            'and try again.',
          );
          return;
        }
        refreshed.add(current);
      }

      final List<int> bytes;
      final String filename;
      final String mimeType;

      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(RegExp(r'[:.]'), '-')
          .split('T')
          .first;

      switch (choice) {
        case 'oblix':
          bytes = await _io.exportNotesOblix(refreshed);
          filename = 'oblix-export-$stamp.oblix';
          mimeType = 'application/zip';
        case 'epub':
          bytes = _io.exportNotesEpub(refreshed);
          filename = 'oblix-export-$stamp.epub';
          mimeType = 'application/epub+zip';
        case 'md':
          bytes = _io.exportNotesMarkdownZip(refreshed);
          filename = 'oblix-notes-$stamp.zip';
          mimeType = 'application/zip';
        case 'txt':
          bytes = _io.exportNotesTextZip(refreshed);
          filename = 'oblix-notes-$stamp.zip';
          mimeType = 'application/zip';
        default:
          return;
      }

      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/$filename';
      await File(path).writeAsBytes(bytes, flush: true);
      if (!mounted) return;
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(path, mimeType: mimeType, name: filename)],
          text: 'Oblix export',
        ),
      );
    } catch (e) {
      _snack('Export failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<List<Note>?> _pickNotesForExport(List<Note> notes) {
    final selectedIds = <String>{};
    return showDialog<List<Note>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Choose notes to export'),
          content: SizedBox(
            width: double.maxFinite,
            height: 420,
            child: Column(
              children: [
                Row(
                  children: [
                    TextButton(
                      onPressed: () => setDialogState(
                        () => selectedIds.addAll(notes.map((note) => note.id)),
                      ),
                      child: const Text('Select all'),
                    ),
                    TextButton(
                      onPressed: () =>
                          setDialogState(() => selectedIds.clear()),
                      child: const Text('Clear'),
                    ),
                    const Spacer(),
                    Text('${selectedIds.length} selected'),
                  ],
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView.builder(
                    itemCount: notes.length,
                    itemBuilder: (context, index) {
                      final note = notes[index];
                      return CheckboxListTile(
                        value: selectedIds.contains(note.id),
                        title: Text(
                          note.title.trim().isEmpty ? 'Untitled' : note.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: note.content.trim().isEmpty
                            ? null
                            : Text(
                                note.content.trim(),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                        onChanged: (checked) => setDialogState(() {
                          if (checked ?? false) {
                            selectedIds.add(note.id);
                          } else {
                            selectedIds.remove(note.id);
                          }
                        }),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: selectedIds.isEmpty
                  ? null
                  : () => Navigator.pop(dialogContext, [
                      for (final note in notes)
                        if (selectedIds.contains(note.id)) note,
                    ]),
              child: const Text('Export'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _exportOption(String key, String label, IconData icon, OblixColors c) {
    return ListTile(
      leading: Icon(icon, color: c.inkSecondary, size: 20),
      title: Text(label, style: OblixType.ui(c, size: 14.5)),
      onTap: () => Navigator.pop(context, key),
    );
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
                  // A ListView hands its children a tight cross-axis width, so
                  // the button's own SizedBox would stretch and centre the disc
                  // mid-page. The Align pins it to the leading edge.
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: CircleIconButton(
                      Icons.arrow_back_ios_new,
                      size: 32,
                      onTap: () => Navigator.pop(context),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 16, 22, 0),
                  child: Text('Settings', style: OblixType.pageTitle(c)),
                ),
                const SectionEyebrow(
                  'Appearance',
                  padding: EdgeInsets.fromLTRB(26, 20, 26, 0),
                ),
                PaperCard(
                  margin: const EdgeInsets.fromLTRB(22, 10, 22, 0),
                  child: Column(
                    children: [
                      ValueListenableBuilder<OblixThemeCollection>(
                        valueListenable: ThemeController.instance.collection,
                        builder: (context, collection, _) => SettingsRow(
                          icon: Icons.palette_outlined,
                          label: 'Theme',
                          value: collection.label,
                          onTap: _pickThemeCollection,
                        ),
                      ),
                      Divider(height: 1, color: c.hairline),
                      ValueListenableBuilder<ThemeMode>(
                        valueListenable: ThemeController.instance.mode,
                        builder: (context, mode, _) => SettingsRow(
                          icon: Icons.brightness_auto_outlined,
                          label: 'Appearance',
                          value: ThemeController.label(mode),
                          onTap: _pickAppearance,
                        ),
                      ),
                      Divider(height: 1, color: c.hairline),
                      ValueListenableBuilder<bool>(
                        valueListenable: ThemeController.instance.liquidGlass,
                        builder: (context, enabled, _) => SettingsRow(
                          icon: Icons.blur_on_outlined,
                          label: 'Liquid Glass',
                          value: enabled ? 'On' : 'Off',
                          showChevron: false,
                          onTap: () =>
                              ThemeController.instance.setLiquidGlass(!enabled),
                          trailing: IgnorePointer(
                            child: Switch.adaptive(
                              value: enabled,
                              activeTrackColor: c.accent,
                              activeThumbColor: c.onAccent,
                              onChanged:
                                  ThemeController.instance.setLiquidGlass,
                            ),
                          ),
                        ),
                      ),
                    ],
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
                      SettingsRow(
                        icon: Icons.file_download_outlined,
                        label: 'Import notes',
                        value: '.enex · .oblix · .md · .txt · .epub',
                        onTap: _busy ? null : _import,
                      ),
                      Divider(height: 1, color: c.hairline),
                      SettingsRow(
                        icon: Icons.file_upload_outlined,
                        label: 'Export notes',
                        value: '.oblix · .epub · .md · .txt',
                        onTap: _busy ? null : _export,
                      ),
                      Divider(height: 1, color: c.hairline),
                      SettingsRow(
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
                      SettingsRow(
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
                    builder: (context, at, _) => SettingsRow(
                      icon: Icons.sync,
                      label: 'Sync now',
                      value: at == null ? 'Never' : Formats.relative(at),
                      onTap: () async {
                        final result = await AppBootstrap.scheduler.syncNow();
                        if (result.skipped) return;
                        _snack(
                          result.success
                              ? 'Synced, ${result.pushed} pushed, '
                                    '${result.pulled} pulled'
                              : 'Sync failed, changes are kept locally',
                        );
                      },
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

class _ThemeSwatch extends StatelessWidget {
  final OblixThemeCollection collection;

  const _ThemeSwatch({required this.collection});

  @override
  Widget build(BuildContext context) {
    final palette = collection == OblixThemeCollection.classic
        ? OblixColors.classicLight
        : OblixColors.paperLight;
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: palette.bg,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: palette.hairline),
      ),
      alignment: Alignment.center,
      child: Container(
        width: 16,
        height: 16,
        decoration: BoxDecoration(
          color: palette.accent,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
