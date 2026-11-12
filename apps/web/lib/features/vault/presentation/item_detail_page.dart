import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:leopard_core/leopard_core.dart';

import '../../../app/theme.dart';
import '../../../core/security/secret_clipboard.dart';
import '../../../core/widgets/feedback.dart';
import '../../../core/widgets/page_scaffold.dart';
import '../../../core/widgets/secret_value_tile.dart';
import '../domain/item_form.dart';
import '../domain/vault_entry.dart';
import 'conflict_dialog.dart';
import 'vault_cubit.dart';

/// Shows one item. Secrets are masked until tapped.
class ItemDetailPage extends StatelessWidget {
  const ItemDetailPage({super.key, required this.id});

  final String id;

  Future<void> _delete(BuildContext context, VaultEntry entry) async {
    final ok = await confirm(
      context,
      title: 'Delete this item?',
      message:
          '"${entry.item.title}" will be removed from the vault on every '
          'device. This cannot be undone.',
      confirmLabel: 'DELETE',
      destructive: true,
    );
    if (!ok || !context.mounted) return;
    final cubit = context.read<VaultCubit>();
    var result = await cubit.delete(entry);
    if (result == SaveResult.conflict && context.mounted) {
      result = await resolveConflicts(context, cubit);
    }
    if (!context.mounted) return;
    if (result == SaveResult.failed) {
      showMessage(context, cubit.state.error ?? 'The item was not deleted.');
    } else if (cubit.state.byId(id) == null) {
      Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<VaultCubit, VaultState>(
      builder: (context, state) {
        final entry = state.byId(id);
        if (entry == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(
              child: Text(
                'This item is no longer in the vault.',
                style: TextStyle(color: LeopardColors.textMuted),
              ),
            ),
          );
        }
        final item = entry.item;
        final values = itemFormValues(item);
        final specs = itemFieldSpecs[item.type] ?? const <ItemFieldSpec>[];
        final clipboard = context.read<SecretClipboard>();
        return Scaffold(
          appBar: AppBar(
            title: Text(itemTypeLabel(item.type).toUpperCase()),
            actions: [
              if (entry.editable)
                IconButton(
                  key: const Key('item-edit'),
                  tooltip: 'Edit',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () => context.push('/vault/edit/$id'),
                ),
              IconButton(
                key: const Key('item-delete'),
                tooltip: 'Delete',
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _delete(context, entry),
              ),
            ],
          ),
          body: WideBody(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: Text(
                    item.title.isEmpty ? '(untitled)' : item.title,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const Divider(),
                if (item is UnknownItem)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      'This item was created by a newer version of Leopard. '
                      'It is kept unchanged and cannot be shown or edited '
                      'here.',
                      style: TextStyle(color: LeopardColors.textMuted),
                    ),
                  ),
                for (final spec in specs)
                  if (spec.key != 'title' &&
                      (values[spec.key] ?? '').isNotEmpty) ...[
                    SecretValueTile(
                      key: Key('field-${spec.key}'),
                      label: _viewLabel(spec),
                      value: values[spec.key]!,
                      secret: spec.secret,
                      onCopy: () => copySecret(
                        context,
                        clipboard,
                        values[spec.key]!,
                        what: '${_viewLabel(spec)} copied',
                      ),
                    ),
                    const Divider(),
                  ],
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'Created ${_date(item.createdAt)} · '
                    'changed ${_date(item.updatedAt)} · '
                    'version ${entry.version}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: LeopardColors.textMuted,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  static String _viewLabel(ItemFieldSpec spec) =>
      spec.label.replaceAll(RegExp(r'\s*\(.*\)$'), '');

  static String _date(DateTime time) {
    final t = time.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)}';
  }
}
