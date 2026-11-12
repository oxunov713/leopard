import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:leopard_ui/leopard_ui.dart';

import '../../../core/security/secret_clipboard.dart';
import '../../../core/widgets/feedback.dart';
import '../../../core/widgets/ui_parts.dart';
import '../domain/item_copy.dart';
import '../domain/vault_entry.dart';
import 'item_detail_page.dart';
import 'item_edit_page.dart';
import 'vault_cubit.dart';
import 'vault_list_page.dart';

enum _PaneMode { view, edit, create }

class _FocusSearchIntent extends Intent {
  const _FocusSearchIntent();
}

class _MoveSelectionIntent extends Intent {
  const _MoveSelectionIntent(this.delta);

  final int delta;
}

class _CopyFieldIntent extends Intent {
  const _CopyFieldIntent({required this.secret});

  /// The secret field (Ctrl+C) or the plain one (Ctrl+B).
  final bool secret;
}

class _EscapeIntent extends Intent {
  const _EscapeIntent();
}

/// The signed-in vault: item list on the left, the open item (or the editor)
/// on the right. In a window narrower than [HomeBreakpoints.rail] one of the
/// two fills the window.
///
/// The route says what to show first ([itemId], [editing], [newType]); from
/// then on the selection is this widget's own state, so that the arrow keys
/// do not fill the browser history.
///
/// Keyboard: Ctrl/Cmd+K focuses the search, Up/Down move the selection,
/// Enter in the search opens the selection, Ctrl/Cmd+C copies the secret of
/// the selected item and Ctrl/Cmd+B its plain field (both through
/// [SecretClipboard], so the 30 s clear applies), Esc clears the search or
/// closes the editor. Copying is left to the text field while one has focus.
class VaultWorkspace extends StatefulWidget {
  const VaultWorkspace({
    super.key,
    this.itemId,
    this.editing = false,
    this.newType,
  });

  final String? itemId;
  final bool editing;
  final String? newType;

  @override
  State<VaultWorkspace> createState() => _VaultWorkspaceState();
}

class _VaultWorkspaceState extends State<VaultWorkspace> {
  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode(debugLabel: 'vault search');
  final FocusNode _rootFocus = FocusNode(
    debugLabel: 'vault workspace',
    skipTraversal: true,
  );
  final ItemEditHandle _editor = ItemEditHandle();

  String? _selectedId;
  _PaneMode _mode = _PaneMode.view;
  String? _newType;

  /// A text field has the focus: it keeps Ctrl+C and friends.
  bool _textFocused = false;

  @override
  void initState() {
    super.initState();
    _search.text = context.read<VaultCubit>().state.query;
    _applyRoute();
    FocusManager.instance.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(VaultWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.itemId != widget.itemId ||
        oldWidget.editing != widget.editing ||
        oldWidget.newType != widget.newType) {
      setState(_applyRoute);
    }
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_onFocusChanged);
    _search.dispose();
    _searchFocus.dispose();
    _rootFocus.dispose();
    super.dispose();
  }

  void _applyRoute() {
    final newType = widget.newType;
    if (newType != null) {
      _mode = _PaneMode.create;
      _newType = newType;
      _selectedId = null;
    } else {
      _newType = null;
      _selectedId = widget.itemId;
      _mode = widget.editing && widget.itemId != null
          ? _PaneMode.edit
          : _PaneMode.view;
    }
  }

  void _onFocusChanged() {
    final focus = FocusManager.instance.primaryFocus;
    final inText =
        focus?.context?.findAncestorWidgetOfExactType<EditableText>() != null;
    if (inText != _textFocused && mounted) {
      setState(() => _textFocused = inText);
    }
  }

  bool get _narrow => MediaQuery.sizeOf(context).width < HomeBreakpoints.rail;

  VaultEntry? get _selected {
    final id = _selectedId;
    return id == null ? null : context.read<VaultCubit>().state.byId(id);
  }

  /// Gives the keyboard back to the workspace when nothing has it (for
  /// instance after a click outside the search field).
  void _onRootFocusChange(bool hasFocus) {
    if (hasFocus) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !TickerMode.valuesOf(context).enabled) return;
      if (ModalRoute.of(context)?.isCurrent != true) return;
      final focus = FocusManager.instance.primaryFocus;
      if (focus == null || focus is FocusScopeNode) {
        _rootFocus.requestFocus();
      }
    });
  }

  // Selection and panes.

  /// Leaves the editor, asking first when it holds typed text.
  Future<bool> _leaveEditor() async {
    if (_mode == _PaneMode.view) return true;
    return _editor.confirmDiscard();
  }

  Future<void> _select(String id) async {
    if (id == _selectedId && _mode == _PaneMode.view) return;
    if (!await _leaveEditor() || !mounted) return;
    setState(() {
      _selectedId = id;
      _mode = _PaneMode.view;
      _newType = null;
    });
  }

  Future<void> _startCreate(String type) async {
    if (!await _leaveEditor() || !mounted) return;
    setState(() {
      _selectedId = null;
      _mode = _PaneMode.create;
      _newType = type;
    });
  }

  void _startEdit() {
    if (_selectedId == null) return;
    setState(() => _mode = _PaneMode.edit);
  }

  /// The editor is done. [savedId] is the item that was saved, or null.
  void _editorClosed(String? savedId) {
    setState(() {
      _mode = _PaneMode.view;
      _newType = null;
      if (savedId != null) _selectedId = savedId;
    });
    _rootFocus.requestFocus();
  }

  void _clearSelection() {
    setState(() {
      _selectedId = null;
      _mode = _PaneMode.view;
    });
  }

  // Keyboard.

  void _focusSearch() {
    _searchFocus.requestFocus();
    _search.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _search.text.length,
    );
  }

  void _move(int delta) {
    final visible = context.read<VaultCubit>().state.visible;
    if (visible.isEmpty) return;
    final index = visible.indexWhere((entry) => entry.id == _selectedId);
    final next = index < 0
        ? (delta > 0 ? 0 : visible.length - 1)
        : math.max(0, math.min(visible.length - 1, index + delta));
    unawaited(_select(visible[next].id));
  }

  /// Enter in the search field.
  void _openFromSearch() {
    final visible = context.read<VaultCubit>().state.visible;
    if (visible.isEmpty) return;
    if (!visible.any((entry) => entry.id == _selectedId)) {
      unawaited(_select(visible.first.id));
    }
    _rootFocus.requestFocus();
  }

  Future<void> _copyField({required bool secret}) async {
    final entry = _selected;
    if (entry == null) return;
    final field = secret
        ? primarySecretField(entry.item)
        : primaryPlainField(entry.item);
    if (field == null) return;
    await copySecret(
      context,
      context.read<SecretClipboard>(),
      field.value,
      what: '${field.label} copied',
    );
  }

  void _escape() {
    final cubit = context.read<VaultCubit>();
    void clearSearch() {
      _search.clear();
      cubit.setQuery('');
    }

    if (_searchFocus.hasFocus) {
      if (_search.text.isNotEmpty) {
        clearSearch();
      } else {
        _rootFocus.requestFocus();
      }
    } else if (_mode != _PaneMode.view) {
      unawaited(_editor.requestClose());
    } else if (_search.text.isNotEmpty) {
      clearSearch();
    }
  }

  Map<ShortcutActivator, Intent> _shortcuts() {
    final editing = _mode != _PaneMode.view;
    final canCopy = !_textFocused && !editing && _selectedId != null;
    final canMove = !_narrow && !editing;
    return {
      for (final modifier in _modifiers) ...{
        modifier(LogicalKeyboardKey.keyK): const _FocusSearchIntent(),
        if (canCopy) ...{
          modifier(LogicalKeyboardKey.keyC): const _CopyFieldIntent(
            secret: true,
          ),
          modifier(LogicalKeyboardKey.keyB): const _CopyFieldIntent(
            secret: false,
          ),
        },
      },
      if (canMove) ...{
        const SingleActivator(LogicalKeyboardKey.arrowDown):
            const _MoveSelectionIntent(1),
        const SingleActivator(LogicalKeyboardKey.arrowUp):
            const _MoveSelectionIntent(-1),
      },
      const SingleActivator(LogicalKeyboardKey.escape): const _EscapeIntent(),
    };
  }

  static final List<SingleActivator Function(LogicalKeyboardKey)> _modifiers = [
    (key) => SingleActivator(key, control: true),
    (key) => SingleActivator(key, meta: true),
  ];

  @override
  Widget build(BuildContext context) {
    final narrow = _narrow;
    final listWidth =
        MediaQuery.sizeOf(context).width >= HomeBreakpoints.sidebar
        ? 380.0
        : 320.0;
    final paneOpen = _selectedId != null || _mode != _PaneMode.view;

    // The list does not change with the selection of a closed pane, so it
    // is built once per build and placed by the layout below.
    final list = VaultListPage(
      searchController: _search,
      searchFocus: _searchFocus,
      selectedId: _selectedId,
      onSelect: _select,
      onNew: _startCreate,
      onSubmitSearch: _openFromSearch,
      showTypeChips: MediaQuery.sizeOf(context).width < HomeBreakpoints.sidebar,
    );

    final Widget body;
    if (narrow) {
      body = paneOpen ? _detail(narrow: true) : list;
    } else {
      body = Row(
        children: [
          SizedBox(width: listWidth, child: list),
          const VerticalDivider(width: 1, color: LeopardColors.surfaceHigh),
          Expanded(child: _detail(narrow: false)),
        ],
      );
    }

    return PopScope(
      canPop: !(narrow && paneOpen),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _clearSelection();
      },
      child: Shortcuts(
        shortcuts: _shortcuts(),
        child: Actions(
          actions: <Type, Action<Intent>>{
            _FocusSearchIntent: CallbackAction<_FocusSearchIntent>(
              onInvoke: (_) {
                _focusSearch();
                return null;
              },
            ),
            _MoveSelectionIntent: CallbackAction<_MoveSelectionIntent>(
              onInvoke: (intent) {
                _move(intent.delta);
                return null;
              },
            ),
            _CopyFieldIntent: CallbackAction<_CopyFieldIntent>(
              onInvoke: (intent) {
                unawaited(_copyField(secret: intent.secret));
                return null;
              },
            ),
            _EscapeIntent: CallbackAction<_EscapeIntent>(
              onInvoke: (_) {
                _escape();
                return null;
              },
            ),
          },
          child: Focus(
            focusNode: _rootFocus,
            autofocus: true,
            onFocusChange: _onRootFocusChange,
            child: body,
          ),
        ),
      ),
    );
  }

  Widget _detail({required bool narrow}) {
    final id = _selectedId;
    if (_mode == _PaneMode.create) {
      return ItemEditPage.create(
        key: ValueKey('create-$_newType'),
        type: _newType ?? '',
        handle: _editor,
        onClose: _editorClosed,
      );
    }
    if (id == null) {
      return const _EmptyDetail();
    }
    if (_mode == _PaneMode.edit) {
      return ItemEditPage.edit(
        key: ValueKey('edit-$id'),
        id: id,
        handle: _editor,
        onClose: _editorClosed,
      );
    }
    return ItemDetailPage(
      key: ValueKey('view-$id'),
      id: id,
      onEdit: _startEdit,
      onDeleted: _clearSelection,
      onBack: narrow ? _clearSelection : null,
    );
  }
}

class _EmptyDetail extends StatelessWidget {
  const _EmptyDetail();

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const LeopardIcon(
          LeopardIcons.vault,
          size: 36,
          color: LeopardColors.outlineStrong,
        ),
        const SizedBox(height: 14),
        const Text(
          'Select an item',
          style: TextStyle(color: LeopardColors.textMuted),
        ),
        const SizedBox(height: 6),
        Text(
          '${shortcutLabel('K')} to search · ↑ ↓ to move',
          style: const TextStyle(fontSize: 12, color: LeopardColors.textMuted),
        ),
      ],
    ),
  );
}
