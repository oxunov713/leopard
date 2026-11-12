import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:leopard_core/leopard_core.dart';
import 'package:leopard_ui/leopard_ui.dart';

import '../../../core/security/secret_clipboard.dart';
import '../../../core/widgets/feedback.dart';
import '../../../core/widgets/page_scaffold.dart';
import '../../../core/widgets/secret_value_tile.dart';
import '../../../core/widgets/tokens.dart';
import '../domain/item_form.dart';
import '../domain/vault_entry.dart';
import 'conflict_dialog.dart';
import 'item_presentation.dart';
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
      confirmLabel: 'Delete',
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
        final shown = [
          for (final spec in specs)
            if (spec.key != 'title' && (values[spec.key] ?? '').isNotEmpty)
              spec,
        ];
        final rows = [
          for (final spec in shown)
            if (!spec.multiline) spec,
        ];
        final blocks = [
          for (final spec in shown)
            if (spec.multiline) spec,
        ];

        Widget tile(ItemFieldSpec spec) => SecretValueTile(
          key: Key('field-${spec.key}'),
          label: fieldViewLabel(spec),
          value: values[spec.key]!,
          secret: spec.secret,
          footer: spec.key == 'password'
              ? _StrengthBar(password: values[spec.key]!)
              : null,
          onCopy: () => copySecret(
            context,
            clipboard,
            values[spec.key]!,
            what: '${fieldViewLabel(spec)} copied',
          ),
        );

        return Scaffold(
          appBar: AppBar(
            actions: [
              if (entry.editable)
                IconButton(
                  key: const Key('item-edit'),
                  tooltip: 'Edit',
                  icon: const LeopardIcon(LeopardIcons.edit),
                  onPressed: () => context.push('/vault/edit/$id'),
                ),
              IconButton(
                key: const Key('item-delete'),
                tooltip: 'Delete',
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _delete(context, entry),
              ),
              const SizedBox(width: 4),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 4, 24),
                child: Column(
                  children: [
                    itemIcon(item.type, size: 72),
                    const SizedBox(height: 12),
                    Text(
                      item.title.isEmpty ? '(untitled)' : item.title,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineLarge,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '${itemTypeLabel(item.type)} · updated '
                      '${relativeTime(item.updatedAt)}',
                      style: const TextStyle(
                        fontSize: 13,
                        color: LeopardColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              if (item is UnknownItem)
                const Panel(
                  child: Text(
                    'This item was created by a newer version of Leopard. '
                    'It is kept unchanged and cannot be shown or edited '
                    'here.',
                    style: TextStyle(color: LeopardColors.textMuted),
                  ),
                ),
              if (rows.isNotEmpty) CardGroup(children: [...rows.map(tile)]),
              for (final spec in blocks) ...[
                const SizedBox(height: 12),
                if (spec.secret)
                  CardGroup(children: [tile(spec)])
                else
                  Panel(
                    key: Key('field-${spec.key}'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 14,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          fieldViewLabel(spec),
                          style: const TextStyle(
                            fontSize: 12,
                            color: LeopardColors.textMuted,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          values[spec.key]!,
                          style: const TextStyle(
                            fontSize: 15,
                            height: 1.5,
                            color: LeopardColors.textSoft,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
              const SizedBox(height: 24),
              const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  LeopardIcon(
                    LeopardIcons.clock,
                    size: 16,
                    color: LeopardColors.textMuted,
                  ),
                  SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      'Hidden again after 20 s · clipboard clears in 30 s',
                      style: TextStyle(
                        fontSize: 12,
                        color: LeopardColors.textMuted,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Created ${_date(item.createdAt)} · '
                'changed ${_date(item.updatedAt)} · '
                'version ${entry.version}',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 12,
                  color: LeopardColors.textMuted,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  static String _date(DateTime time) {
    final t = time.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)}';
  }
}

/// Strength of a stored password: a bar and "Strong · 104 bits".
class _StrengthBar extends StatelessWidget {
  const _StrengthBar({required this.password});

  final String password;

  /// Entropy at which the bar is full.
  static const double _fullScaleBits = 112;

  @override
  Widget build(BuildContext context) {
    final bits = estimatePasswordStrength(password).bits;
    final (label, color) = switch (bits) {
      < 40 => ('Weak', LeopardColors.danger),
      < 60 => ('Fair', warningColor),
      _ => ('Strong', LeopardColors.ok),
    };
    return Row(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              key: const Key('field-password-strength'),
              value: (bits / _fullScaleBits).clamp(0, 1).toDouble(),
              minHeight: 6,
              color: color,
              backgroundColor: LeopardColors.divider,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Text(
          '$label · ${bits.round()} bits',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
      ],
    );
  }
}
