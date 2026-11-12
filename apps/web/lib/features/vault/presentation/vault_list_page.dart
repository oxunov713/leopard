import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:leopard_ui/leopard_ui.dart';

import '../../../core/widgets/ui_parts.dart';
import '../domain/vault_entry.dart';
import 'vault_cubit.dart';

/// The middle pane: search, the "new item" menu and the list of items.
///
/// The selection, the search field and its focus belong to the parent, so
/// that keyboard shortcuts can drive them.
class VaultListPage extends StatelessWidget {
  const VaultListPage({
    super.key,
    required this.searchController,
    required this.searchFocus,
    required this.selectedId,
    required this.onSelect,
    required this.onNew,
    required this.onSubmitSearch,
    this.showTypeChips = false,
  });

  final TextEditingController searchController;
  final FocusNode searchFocus;
  final String? selectedId;
  final ValueChanged<String> onSelect;
  final ValueChanged<String> onNew;
  final VoidCallback onSubmitSearch;

  /// Filter chips above the list, for windows without the sidebar filters.
  final bool showTypeChips;

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<VaultCubit>();
    return BlocBuilder<VaultCubit, VaultState>(
      builder: (context, state) {
        final visible = state.visible;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: _SearchField(
                      controller: searchController,
                      focusNode: searchFocus,
                      onChanged: cubit.setQuery,
                      onSubmitted: onSubmitSearch,
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (state.syncing)
                    const SizedBox(
                      width: 40,
                      height: 40,
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
                      style: IconButton.styleFrom(
                        minimumSize: const Size(40, 40),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      icon: const Icon(
                        Icons.sync,
                        size: 20,
                        color: LeopardColors.textMuted,
                      ),
                      onPressed: cubit.refresh,
                    ),
                  if (state.status == VaultStatus.ready) ...[
                    const SizedBox(width: 4),
                    _NewItemButton(onSelected: onNew),
                  ],
                ],
              ),
            ),
            if (showTypeChips)
              SizedBox(
                height: 44,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  children: [
                    _FilterChip(
                      key: const Key('filter-all'),
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
                VaultStatus.ready =>
                  visible.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              state.entries.isEmpty
                                  ? 'The vault is empty.\nAdd the first item '
                                        'with +.'
                                  : 'Nothing matches.',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: LeopardColors.textMuted,
                              ),
                            ),
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
                          itemCount: visible.length,
                          itemBuilder: (context, index) {
                            final entry = visible[index];
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 2),
                              child: _EntryRow(
                                key: Key('entry-${entry.id}'),
                                entry: entry,
                                selected: entry.id == selectedId,
                                onTap: () => onSelect(entry.id),
                              ),
                            );
                          },
                        ),
              },
            ),
          ],
        );
      },
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onSubmitted,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final VoidCallback onSubmitted;

  @override
  Widget build(BuildContext context) {
    OutlineInputBorder border(Color color, [double width = 1]) =>
        OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: color, width: width),
        );
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) => TextField(
        key: const Key('vault-search'),
        controller: controller,
        focusNode: focusNode,
        onChanged: onChanged,
        onSubmitted: (_) => onSubmitted(),
        autocorrect: false,
        enableSuggestions: false,
        enableIMEPersonalizedLearning: false,
        textInputAction: TextInputAction.search,
        style: const TextStyle(fontSize: 14),
        decoration: InputDecoration(
          hintText: 'Search',
          filled: true,
          fillColor: LeopardColors.surface,
          contentPadding: const EdgeInsets.symmetric(vertical: 11),
          border: border(LeopardColors.divider),
          enabledBorder: border(LeopardColors.divider),
          focusedBorder: border(LeopardColors.primary, 1.5),
          prefixIcon: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12),
            child: LeopardIcon(LeopardIcons.search, size: 16),
          ),
          prefixIconConstraints: const BoxConstraints(minWidth: 40),
          suffixIcon: value.text.isEmpty
              ? Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Kbd(shortcutLabel('K')),
                )
              : IconButton(
                  key: const Key('vault-search-clear'),
                  tooltip: 'Clear',
                  visualDensity: VisualDensity.compact,
                  icon: const LeopardIcon(LeopardIcons.close, size: 16),
                  onPressed: () {
                    controller.clear();
                    onChanged('');
                  },
                ),
          suffixIconConstraints: const BoxConstraints(minWidth: 0),
        ),
      ),
    );
  }
}

class _NewItemButton extends StatelessWidget {
  const _NewItemButton({required this.onSelected});

  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) => Material(
    color: LeopardColors.primary,
    borderRadius: BorderRadius.circular(10),
    clipBehavior: Clip.antiAlias,
    child: PopupMenuButton<String>(
      key: const Key('vault-add'),
      tooltip: 'New item',
      offset: const Offset(0, 44),
      color: LeopardColors.surfaceHigh,
      onSelected: onSelected,
      itemBuilder: (context) => [
        for (final entry in itemTypeLabels.entries)
          PopupMenuItem<String>(
            key: Key('new-${entry.key}'),
            value: entry.key,
            child: Row(
              children: [
                ItemTypeIcon(
                  LeopardItemType.fromTypeName(entry.key) ??
                      LeopardItemType.login,
                  size: 28,
                  radius: 8,
                ),
                const SizedBox(width: 12),
                Text(entry.value),
              ],
            ),
          ),
      ],
      child: const SizedBox(
        width: 40,
        height: 40,
        child: Center(
          child: LeopardIcon(
            LeopardIcons.plus,
            size: 18,
            color: LeopardColors.onPrimary,
          ),
        ),
      ),
    ),
  );
}

class _EntryRow extends StatefulWidget {
  const _EntryRow({
    super.key,
    required this.entry,
    required this.selected,
    required this.onTap,
  });

  final VaultEntry entry;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_EntryRow> createState() => _EntryRowState();
}

class _EntryRowState extends State<_EntryRow> {
  @override
  void didUpdateWidget(_EntryRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selected && !oldWidget.selected) {
      // Keep the row in view when the arrow keys move the selection.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          Scrollable.ensureVisible(
            context,
            duration: const Duration(milliseconds: 120),
          );
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.entry.item;
    final subtitle = entrySubtitle(item);
    final type = LeopardItemType.fromTypeName(item.type);
    final radius = BorderRadius.circular(10);
    return Material(
      color: widget.selected ? LeopardColors.surfaceHigh : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(
          color: widget.selected
              ? LeopardColors.primaryContainer
              : Colors.transparent,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: widget.onTap,
        hoverColor: LeopardColors.surfaceHigh.withValues(alpha: 0.7),
        mouseCursor: SystemMouseCursors.click,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              if (type != null)
                ItemTypeIcon(type, size: 36, radius: 10)
              else
                const SizedBox(width: 36, height: 36),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title.isEmpty ? '(untitled)' : item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (subtitle.isNotEmpty)
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: LeopardColors.textMuted,
                        ),
                      ),
                  ],
                ),
              ),
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
    margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      border: Border.all(color: color),
      borderRadius: BorderRadius.circular(10),
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
          const LeopardIcon(
            LeopardIcons.shieldAlert,
            color: LeopardColors.textMuted,
            size: 36,
          ),
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
