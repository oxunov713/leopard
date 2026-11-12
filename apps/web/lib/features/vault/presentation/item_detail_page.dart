import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:leopard_core/leopard_core.dart';
import 'package:leopard_ui/leopard_ui.dart';

import '../../../core/security/secret_clipboard.dart';
import '../../../core/widgets/feedback.dart';
import '../../../core/widgets/field_row.dart';
import '../../../core/widgets/strength_meter.dart';
import '../../../core/widgets/ui_parts.dart';
import '../domain/item_copy.dart';
import '../domain/item_form.dart';
import '../domain/vault_entry.dart';
import 'conflict_dialog.dart';
import 'vault_cubit.dart';

/// The right pane: one item, with its fields and the buttons to copy them.
///
/// Secrets are masked until revealed. [onBack] is set where the pane fills
/// the window (a phone-sized one) and shows a back arrow.
class ItemDetailPage extends StatelessWidget {
  const ItemDetailPage({
    super.key,
    required this.id,
    required this.onEdit,
    required this.onDeleted,
    this.onBack,
  });

  final String id;
  final VoidCallback onEdit;

  /// The item was deleted; the parent clears its selection.
  final VoidCallback onDeleted;
  final VoidCallback? onBack;

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
      onDeleted();
    }
  }

  @override
  Widget build(BuildContext context) {
    final small = MediaQuery.sizeOf(context).width < HomeBreakpoints.rail;
    return BlocBuilder<VaultCubit, VaultState>(
      builder: (context, state) {
        final entry = state.byId(id);
        if (entry == null) {
          return Column(
            children: [
              if (onBack != null) _BackBar(onBack: onBack!),
              const Expanded(
                child: Center(
                  child: Text(
                    'This item is no longer in the vault.',
                    style: TextStyle(color: LeopardColors.textMuted),
                  ),
                ),
              ),
            ],
          );
        }
        final item = entry.item;
        final values = itemFormValues(item);
        final specs = itemFieldSpecs[item.type] ?? const <ItemFieldSpec>[];
        final clipboard = context.read<SecretClipboard>();
        final type = LeopardItemType.fromTypeName(item.type);
        final secretField = primarySecretField(item);
        final plainField = primaryPlainField(item);
        final shown = [
          for (final spec in specs)
            if (spec.key != 'title' &&
                spec.key != 'notes' &&
                (values[spec.key] ?? '').isNotEmpty)
              spec,
        ];
        final notes = values['notes'] ?? '';
        final password = values['password'] ?? '';
        final padding = small ? 20.0 : 40.0;
        return Column(
          children: [
            if (onBack != null) _BackBar(onBack: onBack!),
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  padding,
                  small ? 12 : 32,
                  padding,
                  32,
                ),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            if (type != null)
                              ItemTypeIcon(type, size: 56, radius: 16),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item.title.isEmpty
                                        ? '(untitled)'
                                        : item.title,
                                    key: const Key('item-title'),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: headingStyle(
                                      28,
                                      letterSpacing: -0.4,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${itemTypeLabel(item.type)} · updated '
                                    '${describeAge(item.updatedAt, DateTime.now())}',
                                    style: const TextStyle(
                                      fontSize: 13,
                                      color: LeopardColors.textMuted,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (entry.editable) ...[
                              const SizedBox(width: 12),
                              _HeaderButton(
                                key: const Key('item-edit'),
                                icon: LeopardIcons.edit,
                                label: 'Edit',
                                iconOnly: small,
                                onPressed: onEdit,
                              ),
                            ],
                            const SizedBox(width: 8),
                            IconButton(
                              key: const Key('item-delete'),
                              tooltip: 'Delete',
                              style: IconButton.styleFrom(
                                minimumSize: const Size(38, 38),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                              icon: const Icon(
                                Icons.delete_outline,
                                size: 20,
                                color: LeopardColors.textMuted,
                              ),
                              onPressed: () => _delete(context, entry),
                            ),
                          ],
                        ),
                        const SizedBox(height: 24),
                        if (item is UnknownItem)
                          const Text(
                            'This item was created by a newer version of '
                            'Leopard. It is kept unchanged and cannot be '
                            'shown or edited here.',
                            style: TextStyle(color: LeopardColors.textMuted),
                          ),
                        if (shown.isNotEmpty)
                          CardPanel(
                            child: Column(
                              children: [
                                for (var i = 0; i < shown.length; i++) ...[
                                  if (i > 0) const Divider(),
                                  _row(
                                    context,
                                    clipboard,
                                    shown[i],
                                    values[shown[i].key]!,
                                    secretField,
                                    plainField,
                                    small,
                                  ),
                                ],
                              ],
                            ),
                          ),
                        if (password.isNotEmpty &&
                            (item is LoginItem || item is WifiItem)) ...[
                          const SizedBox(height: 20),
                          StrengthMeter(
                            bits: estimatePasswordStrength(password).bits,
                            keyed: false,
                          ),
                        ],
                        if (notes.isNotEmpty) ...[
                          const SizedBox(height: 20),
                          CardPanel(
                            padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Notes',
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: LeopardColors.textMuted,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  notes,
                                  key: const Key('field-notes'),
                                  style: const TextStyle(
                                    fontSize: 14,
                                    height: 1.6,
                                    color: LeopardColors.textSoft,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                        const SizedBox(height: 20),
                        Text(
                          'Created ${_date(item.createdAt)} · '
                          'changed ${_date(item.updatedAt)} · '
                          'version ${entry.version}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: LeopardColors.textMuted,
                          ),
                        ),
                        if (!small) ...[
                          const SizedBox(height: 8),
                          const Text(
                            'Clipboard clears 30 s after copying · ↑ ↓ to '
                            'move through the list',
                            style: TextStyle(
                              fontSize: 12,
                              color: LeopardColors.textMuted,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _row(
    BuildContext context,
    SecretClipboard clipboard,
    ItemFieldSpec spec,
    String value,
    CopyField? secretField,
    CopyField? plainField,
    bool small,
  ) {
    final label = _viewLabel(spec);
    final isSecretShortcut = secretField?.key == spec.key;
    final isPlainShortcut = plainField?.key == spec.key;
    return FieldRow(
      key: ValueKey('$id/${spec.key}'),
      contentKey: Key('field-${spec.key}'),
      label: label,
      value: value,
      secret: spec.secret,
      compact: small,
      primaryCopy: isSecretShortcut,
      copyHint: isSecretShortcut
          ? shortcutLabel('C')
          : (isPlainShortcut ? shortcutLabel('B') : null),
      onCopy: () =>
          copySecret(context, clipboard, value, what: '$label copied'),
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

/// "just now", "5 min ago", "3 h ago", "2 days ago" or a date.
String describeAge(DateTime time, DateTime now) {
  final age = now.difference(time);
  if (age.isNegative || age < const Duration(minutes: 1)) return 'just now';
  if (age < const Duration(hours: 1)) return '${age.inMinutes} min ago';
  if (age < const Duration(days: 1)) return '${age.inHours} h ago';
  if (age < const Duration(days: 2)) return 'yesterday';
  if (age < const Duration(days: 30)) return '${age.inDays} days ago';
  final t = time.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)}';
}

class _BackBar extends StatelessWidget {
  const _BackBar({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
    child: Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        key: const Key('pane-back'),
        onPressed: onBack,
        icon: const LeopardIcon(LeopardIcons.back, size: 18),
        label: const Text('Back'),
      ),
    ),
  );
}

class _HeaderButton extends StatelessWidget {
  const _HeaderButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.iconOnly = false,
  });

  final LeopardIconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool iconOnly;

  @override
  Widget build(BuildContext context) {
    if (iconOnly) {
      return IconButton(
        tooltip: label,
        style: IconButton.styleFrom(
          minimumSize: const Size(38, 38),
          side: const BorderSide(color: LeopardColors.outline),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        icon: LeopardIcon(icon, size: 16),
        onPressed: onPressed,
      );
    }
    return OutlinedButton.icon(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 38),
        side: const BorderSide(color: LeopardColors.outline),
      ),
      icon: LeopardIcon(icon, size: 16),
      label: Text(label, style: const TextStyle(fontWeight: FontWeight.w500)),
    );
  }
}
