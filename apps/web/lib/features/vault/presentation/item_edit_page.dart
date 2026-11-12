import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:leopard_core/leopard_core.dart';
import 'package:leopard_ui/leopard_ui.dart';

import '../../../core/error/failures.dart';
import '../../../core/security/password_handoff.dart';
import '../../../core/widgets/feedback.dart';
import '../../../core/widgets/secret_text_field.dart';
import '../../../core/widgets/ui_parts.dart';
import '../domain/item_form.dart';
import '../domain/vault_entry.dart';
import 'conflict_dialog.dart';
import 'vault_cubit.dart';

/// How the parent reaches the editor it shows: to ask before leaving it.
class ItemEditHandle {
  Future<bool> Function()? _confirmDiscard;
  Future<void> Function()? _requestClose;

  /// `true` when the editor may be left without losing typed text.
  Future<bool> confirmDiscard() async => await _confirmDiscard?.call() ?? true;

  /// Closes the editor, after asking if it holds unsaved text.
  Future<void> requestClose() async => _requestClose?.call();
}

/// Creates a new item of [type], or edits the item [id], in the right pane
/// (or over the whole window on a small one).
///
/// [onClose] is called when the user is done, with the id of the item that
/// was saved, or `null` when they cancelled.
class ItemEditPage extends StatefulWidget {
  const ItemEditPage.create({
    super.key,
    required String this.type,
    required this.onClose,
    this.handle,
  }) : id = null;

  const ItemEditPage.edit({
    super.key,
    required String this.id,
    required this.onClose,
    this.handle,
  }) : type = null;

  final String? id;
  final String? type;
  final ValueChanged<String?> onClose;
  final ItemEditHandle? handle;

  @override
  State<ItemEditPage> createState() => _ItemEditPageState();
}

class _ItemEditPageState extends State<ItemEditPage> {
  late final VaultEntry? _base;
  late final String _type;
  late final List<ItemFieldSpec> _specs;
  final Map<String, TextEditingController> _controllers = {};
  late final Map<String, String> _initial;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final id = widget.id;
    _base = id == null ? null : context.read<VaultCubit>().state.byId(id);
    _type = _base?.item.type ?? widget.type ?? '';
    _specs = itemFieldSpecs[_type] ?? const [];
    // A password handed over by the generator. It travels in memory, never
    // in the route: route data can end up in the browser's history.
    final handedOver = _base == null && _type == LoginItem.typeName
        ? context.read<PasswordHandoff>().take()
        : null;
    final values = _base == null
        ? <String, String>{
            if (_type == WifiItem.typeName) 'security': WifiItem.securityWpa2,
            'password': ?handedOver,
          }
        : itemFormValues(_base.item);
    _initial = {for (final spec in _specs) spec.key: values[spec.key] ?? ''};
    widget.handle
      ?.._confirmDiscard = confirmDiscard
      .._requestClose = requestClose;
    for (final spec in _specs) {
      _controllers[spec.key] = TextEditingController(text: _initial[spec.key]);
    }
  }

  @override
  void dispose() {
    final handle = widget.handle;
    // A newer editor may have taken the handle over already.
    if (handle != null && handle._confirmDiscard == confirmDiscard) {
      handle
        .._confirmDiscard = null
        .._requestClose = null;
    }
    for (final controller in _controllers.values) {
      controller.clear();
      controller.dispose();
    }
    _initial.clear();
    super.dispose();
  }

  bool get _dirty => _controllers.entries.any(
    (entry) => entry.value.text != _initial[entry.key],
  );

  /// Asks before throwing away typed text. `true` when the editor may go.
  Future<bool> confirmDiscard() async {
    if (!_dirty || _saving) return true;
    return confirm(
      context,
      title: 'Discard changes?',
      message: 'What you typed has not been saved.',
      confirmLabel: 'Discard',
      destructive: true,
    );
  }

  /// The Cancel button and the Escape key.
  Future<void> requestClose() async {
    if (await confirmDiscard() && mounted) {
      widget.onClose(null);
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    final cubit = context.read<VaultCubit>();
    final VaultItem item;
    try {
      item = buildItem(
        type: _type,
        values: {
          for (final entry in _controllers.entries) entry.key: entry.value.text,
        },
        now: DateTime.now().toUtc(),
        original: _base?.item,
      );
    } on ValidationFailure catch (e) {
      setState(() => _error = e.message);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final known = {for (final entry in cubit.state.entries) entry.id};
    final base = _base;
    var result = base == null
        ? await cubit.create(item)
        : await cubit.update(base, item);
    if (result == SaveResult.conflict && mounted) {
      result = await resolveConflicts(context, cubit);
    }
    if (result == SaveResult.deletedRemotely && mounted) {
      final again = await confirm(
        context,
        title: 'Deleted on another device',
        message:
            'This item was deleted somewhere else while you were editing '
            'it. Save what you typed as a new item?',
        confirmLabel: 'Save as new',
      );
      result = again ? await cubit.create(item) : SaveResult.saved;
    }
    if (!mounted) return;
    if (result == SaveResult.saved) {
      // The id of a new item is whichever one appeared.
      final savedId =
          base?.id ??
          cubit.state.entries
              .map((entry) => entry.id)
              .where((id) => !known.contains(id))
              .firstOrNull;
      widget.onClose(savedId);
    } else {
      setState(() {
        _saving = false;
        _error = cubit.state.error ?? 'The item was not saved.';
      });
    }
  }

  void _generatePassword(String key) {
    _controllers[key]?.text = generatePassword();
    showMessage(context, 'A new 20-character password was filled in.');
  }

  @override
  Widget build(BuildContext context) {
    final small = MediaQuery.sizeOf(context).width < HomeBreakpoints.rail;
    final padding = small ? 20.0 : 40.0;
    if (_specs.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'This item cannot be edited.',
              style: TextStyle(color: LeopardColors.textMuted),
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: () => widget.onClose(null),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    }
    final type = LeopardItemType.fromTypeName(_type);
    final base = _base;
    final title = base == null
        ? 'New ${itemTypeLabel(_type).toLowerCase()}'
        : 'Edit ${base.item.title.isEmpty ? '(untitled)' : base.item.title}';
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(padding, small ? 16 : 32, padding, 32),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (type != null) ItemTypeIcon(type, size: 44, radius: 12),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      title,
                      key: const Key('edit-title-heading'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: headingStyle(24, letterSpacing: -0.3),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              CardPanel(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final spec in _specs) ...[
                      _field(spec),
                      const SizedBox(height: 14),
                    ],
                    if (_type == CardItem.typeName)
                      const Text(
                        'The security code (CVV) is never stored.',
                        style: TextStyle(
                          fontSize: 12,
                          color: LeopardColors.textMuted,
                        ),
                      ),
                    if (_error != null) ...[
                      const SizedBox(height: 8),
                      ErrorText(_error!, key: const Key('edit-error')),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  FilledButton(
                    key: const Key('item-save'),
                    onPressed: _saving ? null : _save,
                    child: Text(_saving ? 'Saving…' : 'Save'),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton(
                    key: const Key('item-cancel'),
                    onPressed: _saving ? null : requestClose,
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 12),
                  if (!small) const Kbd('Esc'),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _field(ItemFieldSpec spec) {
    final controller = _controllers[spec.key]!;
    final options = spec.options;
    if (options != null) {
      final known = options.contains(controller.text);
      return DropdownButtonFormField<String>(
        key: Key('edit-${spec.key}'),
        initialValue: controller.text,
        decoration: InputDecoration(labelText: spec.label),
        dropdownColor: LeopardColors.surfaceHigh,
        items: [
          // A value written by another client is kept selectable as it is.
          if (!known)
            DropdownMenuItem(
              value: controller.text,
              child: Text(controller.text),
            ),
          for (final option in options)
            DropdownMenuItem(value: option, child: Text(option.toUpperCase())),
        ],
        onChanged: _saving
            ? null
            : (value) => controller.text = value ?? controller.text,
      );
    }
    if (spec.secret) {
      final canGenerate =
          spec.key == 'password' &&
          (_type == LoginItem.typeName || _type == WifiItem.typeName);
      final field = SecretTextField(
        key: Key('edit-${spec.key}'),
        controller: controller,
        label: spec.label,
        enabled: !_saving,
        multiline: spec.multiline,
        keyboardType: spec.numeric ? TextInputType.number : null,
      );
      if (!canGenerate) return field;
      return Row(
        children: [
          Expanded(child: field),
          const SizedBox(width: 8),
          IconButton(
            key: const Key('edit-generate'),
            tooltip: 'Generate password',
            icon: const LeopardIcon(LeopardIcons.generator, size: 20),
            onPressed: _saving ? null : () => _generatePassword(spec.key),
          ),
        ],
      );
    }
    return TextField(
      key: Key('edit-${spec.key}'),
      controller: controller,
      enabled: !_saving,
      minLines: spec.multiline ? 2 : 1,
      maxLines: spec.multiline ? 6 : 1,
      keyboardType: spec.numeric
          ? TextInputType.number
          : (spec.multiline ? TextInputType.multiline : TextInputType.text),
      inputFormatters: spec.numeric
          ? [FilteringTextInputFormatter.digitsOnly]
          : null,
      autocorrect: false,
      enableSuggestions: false,
      enableIMEPersonalizedLearning: false,
      decoration: InputDecoration(labelText: spec.label),
    );
  }
}
