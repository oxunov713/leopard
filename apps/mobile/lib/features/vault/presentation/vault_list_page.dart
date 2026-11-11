import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:leopard_core/leopard_core.dart';

import '../../../app/theme.dart';
import '../../../core/lock/app_lock_cubit.dart';
import '../domain/vault_entry.dart';
import 'vault_cubit.dart';

IconData itemTypeIcon(String type) => switch (type) {
  LoginItem.typeName => Icons.person_outline,
  CardItem.typeName => Icons.credit_card_outlined,
  WifiItem.typeName => Icons.wifi,
  ApiKeyItem.typeName => Icons.vpn_key_outlined,
  SshKeyItem.typeName => Icons.terminal,
  SecureNoteItem.typeName => Icons.sticky_note_2_outlined,
  _ => Icons.help_outline,
};

/// The list of items with search and a type filter.
class VaultListPage extends StatelessWidget {
  const VaultListPage({super.key});

  Future<void> _add(BuildContext context) async {
    final type = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: LeopardColors.surfaceHigh,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final entry in itemTypeLabels.entries)
              ListTile(
                key: Key('new-${entry.key}'),
                leading: Icon(itemTypeIcon(entry.key)),
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
          appBar: AppBar(
            title: const Text('VAULT'),
            actions: [
              if (state.syncing)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                IconButton(
                  key: const Key('vault-sync'),
                  tooltip: 'Sync',
                  icon: const Icon(Icons.sync),
                  onPressed: cubit.refresh,
                ),
              IconButton(
                key: const Key('vault-lock'),
                tooltip: 'Lock',
                icon: const Icon(Icons.lock_outline),
                onPressed: context.read<AppLockCubit>().lock,
              ),
            ],
          ),
          floatingActionButton: state.status == VaultStatus.ready
              ? FloatingActionButton(
                  key: const Key('vault-add'),
                  tooltip: 'New item',
                  onPressed: () => _add(context),
                  child: const Icon(Icons.add),
                )
              : null,
          body: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: TextField(
                  key: const Key('vault-search'),
                  onChanged: cubit.setQuery,
                  autocorrect: false,
                  enableSuggestions: false,
                  enableIMEPersonalizedLearning: false,
                  textInputAction: TextInputAction.search,
                  decoration: const InputDecoration(
                    hintText: 'Search',
                    prefixIcon: Icon(Icons.search),
                    isDense: true,
                  ),
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
                    for (final entry in itemTypeLabels.entries)
                      _FilterChip(
                        key: Key('filter-${entry.key}'),
                        label: entry.value,
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
                  color: LeopardColors.warning,
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
                    color: LeopardColors.brass,
                    backgroundColor: LeopardColors.surfaceHigh,
                    onRefresh: cubit.refresh,
                    child: visible.isEmpty
                        ? ListView(
                            children: [
                              const SizedBox(height: 96),
                              Center(
                                child: Text(
                                  state.entries.isEmpty
                                      ? 'The vault is empty.\nAdd the first '
                                            'item with +.'
                                      : 'Nothing matches.',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: LeopardColors.textMuted,
                                  ),
                                ),
                              ),
                            ],
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.only(bottom: 88),
                            itemCount: visible.length,
                            separatorBuilder: (_, _) =>
                                const Divider(indent: 56),
                            itemBuilder: (context, index) {
                              final entry = visible[index];
                              final subtitle = entrySubtitle(entry.item);
                              return ListTile(
                                key: Key('entry-${entry.id}'),
                                leading: Icon(itemTypeIcon(entry.item.type)),
                                title: Text(
                                  entry.item.title.isEmpty
                                      ? '(untitled)'
                                      : entry.item.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: subtitle.isEmpty
                                    ? null
                                    : Text(
                                        subtitle,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: LeopardColors.textMuted,
                                        ),
                                      ),
                                onTap: () =>
                                    context.push('/vault/item/${entry.id}'),
                              );
                            },
                          ),
                  ),
                },
              ),
            ],
          ),
        );
      },
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
    child: ChoiceChip(
      label: Text(label),
      selected: selected,
      showCheckmark: false,
      onSelected: (_) => onSelected(),
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
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      border: Border.all(color: color),
      borderRadius: BorderRadius.circular(6),
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
            child: const Text('TRY AGAIN'),
          ),
        ],
      ),
    ),
  );
}
