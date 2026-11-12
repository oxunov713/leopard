import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:leopard_core/leopard_core.dart';
import 'package:leopard_ui/leopard_ui.dart';

import '../../../core/lock/app_lock_cubit.dart';
import '../../../core/security/secret_clipboard.dart';
import '../../../core/widgets/feedback.dart';
import '../../../core/widgets/page_scaffold.dart';
import '../../../core/widgets/tokens.dart';
import '../domain/vault_entry.dart';
import 'item_presentation.dart';
import 'vault_cubit.dart';

/// Short names of the item types on the filter chips.
const Map<String, String> _filterLabels = {
  LoginItem.typeName: 'Logins',
  CardItem.typeName: 'Cards',
  WifiItem.typeName: 'Wi-Fi',
  ApiKeyItem.typeName: 'API keys',
  SshKeyItem.typeName: 'SSH keys',
  SecureNoteItem.typeName: 'Notes',
};

/// The list of items with search and a type filter.
class VaultListPage extends StatelessWidget {
  const VaultListPage({super.key});

  Future<void> _add(BuildContext context) async {
    final type = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                'New item',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
            for (final entry in itemTypeLabels.entries)
              ListTile(
                key: Key('new-${entry.key}'),
                minTileHeight: 56,
                leading: itemIcon(entry.key, size: 40),
                title: Text(entry.value),
                onTap: () => Navigator.of(context).pop(entry.key),
              ),
          ],
        ),
      ),
    );
    if (type != null && context.mounted) {
      await context.push('/vault/new/$type');
    }
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<VaultCubit>();
    return BlocBuilder<VaultCubit, VaultState>(
      builder: (context, state) {
        final visible = state.visible;
        return Scaffold(
          floatingActionButton: state.status == VaultStatus.ready
              ? FloatingActionButton.extended(
                  key: const Key('vault-add'),
                  tooltip: 'New item',
                  onPressed: () => _add(context),
                  icon: const LeopardIcon(
                    LeopardIcons.plus,
                    size: 20,
                    color: LeopardColors.onPrimary,
                  ),
                  label: const Text(
                    'New item',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                )
              : null,
          body: SafeArea(
            bottom: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 12, 0),
                  child: Row(
                    children: [
                      const LeopardMark(size: 26),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          'LEOPARD',
                          style: TextStyle(
                            fontFamily: LeopardFonts.heading,
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                            letterSpacing: 1.5,
                            color: LeopardColors.textMuted,
                          ),
                        ),
                      ),
                      if (state.syncing)
                        const SizedBox(
                          width: 44,
                          height: 44,
                          child: Center(
                            child: SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        )
                      else
                        IconButton(
                          key: const Key('vault-sync'),
                          tooltip: 'Sync',
                          icon: const Icon(
                            Icons.sync,
                            color: LeopardColors.textMuted,
                          ),
                          onPressed: cubit.refresh,
                        ),
                      IconButton(
                        key: const Key('vault-lock'),
                        tooltip: 'Lock',
                        style: IconButton.styleFrom(
                          backgroundColor: LeopardColors.surfaceHigh,
                          minimumSize: const Size(44, 44),
                        ),
                        icon: const LeopardIcon(LeopardIcons.lock, size: 20),
                        onPressed: context.read<AppLockCubit>().lock,
                      ),
                    ],
                  ),
                ),
                const LargeTitle('Vault'),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: _SearchField(
                    count: state.entries.length,
                    onChanged: cubit.setQuery,
                  ),
                ),
                SizedBox(
                  height: 44,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    children: [
                      _FilterChip(
                        label: 'All',
                        selected: state.typeFilter == null,
                        onSelected: () => cubit.setTypeFilter(null),
                      ),
                      for (final entry in _filterLabels.entries)
                        _FilterChip(
                          key: Key('filter-${entry.key}'),
                          label:
                              '${entry.value} '
                              '${state.entries.where((e) => e.item.type == entry.key).length}',
                          selected: state.typeFilter == entry.key,
                          onSelected: () => cubit.setTypeFilter(entry.key),
                        ),
                    ],
                  ),
                ),
                if (state.error != null && state.status == VaultStatus.ready)
                  _Banner(text: state.error!, color: LeopardColors.danger),
                if (state.unreadableCount > 0)
                  _Banner(
                    text:
                        '${state.unreadableCount} item'
                        '${state.unreadableCount == 1 ? '' : 's'} on the '
                        'server could not be decrypted with this vault key '
                        'and ${state.unreadableCount == 1 ? 'is' : 'are'} '
                        'not shown.',
                    color: warningColor,
                  ),
                Expanded(
                  child: switch (state.status) {
                    VaultStatus.initial || VaultStatus.loading => const Center(
                      child: CircularProgressIndicator(),
                    ),
                    VaultStatus.failure => _LoadFailure(
                      message: state.error ?? 'The vault could not be loaded.',
                      onRetry: cubit.load,
                    ),
                    VaultStatus.ready => RefreshIndicator(
                      color: LeopardColors.primary,
                      backgroundColor: LeopardColors.surfaceHigh,
                      onRefresh: cubit.refresh,
                      child: visible.isEmpty
                          ? ListView(
                              children: [
                                const SizedBox(height: 72),
                                Center(
                                  child: Text(
                                    state.entries.isEmpty
                                        ? 'The vault is empty.\nAdd the first '
                                              'item with New item.'
                                        : 'Nothing matches.',
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      color: LeopardColors.textMuted,
                                    ),
                                  ),
                                ),
                              ],
                            )
                          : ListView.builder(
                              padding: const EdgeInsets.fromLTRB(8, 4, 8, 96),
                              itemCount: visible.length,
                              itemBuilder: (context, index) =>
                                  _EntryRow(entry: visible[index]),
                            ),
                    ),
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.count, required this.onChanged});

  final int count;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    const noBorder = OutlineInputBorder(
      borderRadius: BorderRadius.all(Radius.circular(26)),
      borderSide: BorderSide.none,
    );
    return TextField(
      key: const Key('vault-search'),
      onChanged: onChanged,
      autocorrect: false,
      enableSuggestions: false,
      enableIMEPersonalizedLearning: false,
      textInputAction: TextInputAction.search,
      style: const TextStyle(fontSize: 15),
      decoration: InputDecoration(
        hintText: 'Search $count item${count == 1 ? '' : 's'}',
        prefixIcon: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: LeopardIcon(LeopardIcons.search, size: 20),
        ),
        prefixIconConstraints: const BoxConstraints(minWidth: 52),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 16,
        ),
        border: noBorder,
        enabledBorder: noBorder,
      ),
    );
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({required this.entry});

  final VaultEntry entry;

  @override
  Widget build(BuildContext context) {
    final item = entry.item;
    final subtitle = entrySubtitle(item);
    final secret = copyableSecretOf(item);
    return InkWell(
      key: Key('entry-${entry.id}'),
      borderRadius: BorderRadius.circular(16),
      onTap: () => context.push('/vault/item/${entry.id}'),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 64),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
          child: Row(
            children: [
              itemIcon(item.type),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title.isEmpty ? '(untitled)' : item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (subtitle.isNotEmpty)
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          color: LeopardColors.textMuted,
                        ),
                      ),
                  ],
                ),
              ),
              if (secret != null)
                IconButton(
                  tooltip: 'Copy ${secret.label.toLowerCase()}',
                  icon: const LeopardIcon(
                    LeopardIcons.copy,
                    color: LeopardColors.textMuted,
                  ),
                  onPressed: () => copySecret(
                    context,
                    context.read<SecretClipboard>(),
                    secret.value,
                    what: '${secret.label} copied',
                  ),
                )
              else
                const SizedBox(width: 12),
            ],
          ),
        ),
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onSelected,
        child: SizedBox(
          height: 44,
          child: Center(
            child: Container(
              height: 36,
              padding: EdgeInsets.symmetric(horizontal: selected ? 16 : 14),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected ? LeopardColors.primary : null,
                borderRadius: BorderRadius.circular(10),
                border: selected
                    ? null
                    : Border.all(color: LeopardColors.outlineStrong),
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected
                      ? LeopardColors.onPrimary
                      : LeopardColors.text,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Text(text, style: TextStyle(color: color, fontSize: 13)),
  );
}

class _LoadFailure extends StatelessWidget {
  const _LoadFailure({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off, color: LeopardColors.textMuted, size: 40),
          const SizedBox(height: 16),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 20),
          OutlinedButton(
            key: const Key('vault-retry'),
            onPressed: onRetry,
            child: const Text('Try again'),
          ),
        ],
      ),
    ),
  );
}
