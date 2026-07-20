import 'package:flutter/material.dart';
import '../../core/network/api_exceptions.dart';
import '../../data/datasources/remote/ai_remote_datasource.dart';
import '../../data/models/note.dart';
import '../theme/oblix_theme.dart';
import '../widgets/paper.dart';

/// "Ask Oblix" actions on a note. Summarize calls the backend's /ai/summarize
/// (only offered when the server reports AI is configured); Extract tasks /
/// Tidy up / Translate are designed but have no backend yet, so they show the
/// coming-soon sheet.
///
/// Returns the summary text if the user chose to insert it into the note.
Future<String?> showAiActionsSheet(BuildContext context, Note note) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _AiActionsSheet(note: note),
  );
}

class _AiActionsSheet extends StatefulWidget {
  final Note note;
  const _AiActionsSheet({required this.note});

  @override
  State<_AiActionsSheet> createState() => _AiActionsSheetState();
}

class _AiActionsSheetState extends State<_AiActionsSheet> {
  final _ai = AiRemoteDataSource();

  bool? _enabled; // null = still checking
  bool _running = false;
  String? _summary;
  String? _error;

  @override
  void initState() {
    super.initState();
    _checkStatus();
  }

  Future<void> _checkStatus() async {
    try {
      final status = await _ai.status();
      if (mounted) setState(() => _enabled = status.enabled);
    } catch (_) {
      // Offline or older server: treat as unavailable rather than erroring.
      if (mounted) setState(() => _enabled = false);
    }
  }

  Future<void> _summarize() async {
    if (_running) return;
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      final summary = await _ai.summarize(widget.note.id);
      if (mounted) setState(() => _summary = summary);
    } on RateLimitedException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() => _error = e.message.isEmpty
            ? 'Could not summarize this note.'
            : e.message);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not reach the server. Try again once '
            'you are back online.');
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const SheetGrabHandle(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                children: [
                  Icon(Icons.auto_awesome, size: 17, color: c.accent),
                  const SizedBox(width: 9),
                  Text(
                    'Ask Oblix',
                    style: TextStyle(
                      fontFamily: OblixType.serif,
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      color: c.ink,
                    ),
                  ),
                ],
              ),
            ),
            if (_enabled == false)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 14, 24, 0),
                child: Text(
                  'AI features are switched off on this server. Ask your '
                  'admin to set an API key to turn them on.',
                  style: OblixType.ui(c, size: 13, color: c.inkMuted),
                ),
              ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                children: [
                  _ActionRow(
                    icon: Icons.notes,
                    title: 'Summarize',
                    subtitle: 'Three-line recap at the top',
                    enabled: _enabled ?? false,
                    busy: _running,
                    onTap: _summarize,
                  ),
                  Divider(height: 1, color: c.hairline),
                  _ActionRow(
                    icon: Icons.checklist,
                    title: 'Extract tasks',
                    subtitle: 'Turn action items into tasks',
                    enabled: true,
                    onTap: () => showComingSoon(
                      context,
                      icon: Icons.checklist,
                      title: 'Extract tasks',
                      subtitle:
                          'Oblix will pull action items out of a note and '
                          'file them in your Tasks tab.',
                    ),
                  ),
                  Divider(height: 1, color: c.hairline),
                  _ActionRow(
                    icon: Icons.auto_fix_high,
                    title: 'Tidy up',
                    subtitle: 'Fix grammar, keep your voice',
                    enabled: true,
                    onTap: () => showComingSoon(
                      context,
                      icon: Icons.auto_fix_high,
                      title: 'Tidy up',
                      subtitle:
                          'Cleans up grammar and spacing while keeping how '
                          'you write.',
                    ),
                  ),
                  Divider(height: 1, color: c.hairline),
                  _ActionRow(
                    icon: Icons.translate,
                    title: 'Translate',
                    subtitle: 'Pick a language',
                    enabled: true,
                    onTap: () => showComingSoon(
                      context,
                      icon: Icons.translate,
                      title: 'Translate',
                      subtitle: 'Rewrite a note in another language, '
                          'keeping the original alongside.',
                    ),
                  ),
                ],
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                child: Text(
                  _error!,
                  style: OblixType.ui(c, size: 13, color: c.danger),
                ),
              ),
            if (_summary != null) ...[
              PaperCard(
                margin: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.auto_awesome, size: 11, color: c.accent),
                        const SizedBox(width: 6),
                        Text('SUMMARY',
                            style: OblixType.eyebrow(c, color: c.accent)),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(_summary!, style: OblixType.noteBody(c)),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Material(
                        color: c.accent,
                        shape: const StadiumBorder(),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: () => Navigator.pop(context, _summary),
                          child: Padding(
                            padding: const EdgeInsets.all(13),
                            child: Center(
                              child: Text(
                                'Insert at top',
                                style: OblixType.ui(c,
                                    size: 14.5,
                                    weight: FontWeight.w600,
                                    color: c.onAccent),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool enabled;
  final bool busy;
  final VoidCallback onTap;

  const _ActionRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.enabled,
    this.busy = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: InkWell(
        onTap: enabled && !busy ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 13),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: c.accentSoft,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 16, color: c.accent),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: OblixType.ui(c,
                            size: 15, weight: FontWeight.w600)),
                    Text(subtitle,
                        style: OblixType.ui(c, size: 12, color: c.inkMuted)),
                  ],
                ),
              ),
              if (busy)
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: c.accent),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
