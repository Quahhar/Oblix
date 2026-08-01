import 'package:flutter/material.dart';

import '../../core/network/api_exceptions.dart';
import '../../data/datasources/remote/collaboration_remote_datasource.dart';
import '../theme/oblix_theme.dart';
import '../widgets/paper.dart';

Future<void> showManageAccessSheet(
  BuildContext context, {
  required CollaborationRemoteDataSource remote,
  required String entityType,
  required String entityId,
  required String name,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => FractionallySizedBox(
      heightFactor: .82,
      child: _ManageAccessSheet(
        remote: remote,
        entityType: entityType,
        entityId: entityId,
        name: name,
      ),
    ),
  );
}

class _ManageAccessSheet extends StatefulWidget {
  final CollaborationRemoteDataSource remote;
  final String entityType;
  final String entityId;
  final String name;

  const _ManageAccessSheet({
    required this.remote,
    required this.entityType,
    required this.entityId,
    required this.name,
  });

  @override
  State<_ManageAccessSheet> createState() => _ManageAccessSheetState();
}

class _ManageAccessSheetState extends State<_ManageAccessSheet> {
  late Future<List<Collaborator>> _items = _load();

  Future<List<Collaborator>> _load() => widget.remote.collaborators(
    entityType: widget.entityType,
    entityId: widget.entityId,
  );

  void _reload() {
    if (!mounted) return;
    setState(() => _items = _load());
  }

  String _errorMessage(Object error) =>
      error is ApiException ? error.message : 'Please try again.';

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _invite() async {
    final email = TextEditingController();
    final formKey = GlobalKey<FormState>();
    var role = 'editor';
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Add a collaborator'),
          content: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: email,
                  autofocus: true,
                  keyboardType: TextInputType.emailAddress,
                  autocorrect: false,
                  decoration: const InputDecoration(labelText: 'Account email'),
                  validator: (value) {
                    final text = value?.trim() ?? '';
                    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(text)) {
                      return 'Enter a valid email address';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: role,
                  decoration: const InputDecoration(labelText: 'Permission'),
                  items: const [
                    DropdownMenuItem(value: 'editor', child: Text('Can edit')),
                    DropdownMenuItem(value: 'viewer', child: Text('Can view')),
                  ],
                  onChanged: (value) =>
                      setDialogState(() => role = value ?? 'editor'),
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
              onPressed: () {
                if (formKey.currentState?.validate() ?? false) {
                  Navigator.pop(dialogContext, (email.text.trim(), role));
                }
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
    email.dispose();
    if (result == null || !mounted) return;
    try {
      await widget.remote.share(
        entityType: widget.entityType,
        entityId: widget.entityId,
        email: result.$1,
        role: result.$2,
      );
      _toast('Access granted to ${result.$1}');
      _reload();
    } catch (error) {
      _toast(_errorMessage(error));
    }
  }

  Future<void> _changeRole(Collaborator collaborator, String role) async {
    if (role == collaborator.role) return;
    try {
      await widget.remote.updateRole(collaborator.id, role);
      if (!mounted) return;
      _reload();
    } catch (error) {
      _toast(_errorMessage(error));
    }
  }

  Future<void> _remove(Collaborator collaborator) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove access?'),
        content: Text(
          '${collaborator.displayName.isEmpty ? collaborator.email : collaborator.displayName} '
          'will no longer be able to open this ${widget.entityType}.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.remote.removeShare(collaborator.id);
      if (!mounted) return;
      _reload();
    } catch (error) {
      _toast(_errorMessage(error));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    return Column(
      children: [
        const SheetGrabHandle(),
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 4, 14, 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Manage access', style: OblixType.pageTitle(c)),
                    const SizedBox(height: 3),
                    Text(
                      widget.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: OblixType.ui(c, size: 13, color: c.inkMuted),
                    ),
                  ],
                ),
              ),
              TextButton.icon(
                onPressed: _invite,
                icon: const Icon(Icons.person_add_alt_1_outlined, size: 18),
                label: const Text('Add'),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: c.hairline),
        Expanded(
          child: FutureBuilder<List<Collaborator>>(
            future: _items,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return Center(
                  child: TextButton(
                    onPressed: _reload,
                    child: const Text('Could not load access. Try again'),
                  ),
                );
              }
              final items = snapshot.data ?? const [];
              if (items.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Only you can access this ${widget.entityType}.',
                      textAlign: TextAlign.center,
                      style: OblixType.ui(c, size: 14, color: c.inkMuted),
                    ),
                  ),
                );
              }
              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                itemCount: items.length,
                separatorBuilder: (_, _) =>
                    Divider(height: 1, color: c.hairline),
                itemBuilder: (context, index) {
                  final collaborator = items[index];
                  final name = collaborator.displayName.isEmpty
                      ? collaborator.email
                      : collaborator.displayName;
                  return ListTile(
                    leading: OblixAvatar(name: name, size: 36),
                    title: Text(name),
                    subtitle: Text(
                      collaborator.displayName.isEmpty
                          ? collaborator.role
                          : '${collaborator.email} · ${collaborator.role}',
                    ),
                    trailing: PopupMenuButton<String>(
                      tooltip: 'Change access for $name',
                      onSelected: (value) {
                        if (value == 'remove') {
                          _remove(collaborator);
                        } else {
                          _changeRole(collaborator, value);
                        }
                      },
                      itemBuilder: (_) => [
                        CheckedPopupMenuItem(
                          value: 'editor',
                          checked: collaborator.role == 'editor',
                          child: const Text('Can edit'),
                        ),
                        CheckedPopupMenuItem(
                          value: 'viewer',
                          checked: collaborator.role == 'viewer',
                          child: const Text('Can view'),
                        ),
                        const PopupMenuDivider(),
                        const PopupMenuItem(
                          value: 'remove',
                          child: Text('Remove access'),
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}
