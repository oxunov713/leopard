import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:leopard_core/leopard_core.dart';

import '../../../app/theme.dart';
import '../../../core/error/failures.dart';
import '../../../core/security/password_handoff.dart';
import '../../../core/widgets/feedback.dart';
import '../../../core/widgets/page_scaffold.dart';
import '../../../core/widgets/secret_text_field.dart';
import '../domain/item_form.dart';
import '../domain/vault_entry.dart';
import 'conflict_dialog.dart';
import 'vault_cubit.dart';

/// Creates a new item of [type], or edits the item [id].
class ItemEditPage extends StatefulWidget {
  const ItemEditPage.create({super.key, required String this.type})
    : id = null;

  const ItemEditPage.edit({super.key, required String this.id}) : type = null;

  final String? id;
  final String? type;

  @override
  State<ItemEditPage> createState() => _ItemEditPageState();
}

class _ItemEditPageState extends State<ItemEditPage> {
  late final VaultEntry? _base;
  late final String _type;
  late final List<ItemFieldSpec> _specs;
  final Map<String, TextEditingController> _controllers = {};
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
    for (final spec in _specs) {
      _controllers[spec.key] = TextEditingController(
        text: values[spec.key] ?? '',
      );
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.clear();
      controller.dispose();
    }
    super.dispose();
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
        confirmLabel: 'SAVE AS NEW',
      );
      result = again ? await cubit.create(item) : SaveResult.saved;
    }
    if (!mounted) return;
    if (result == SaveResult.saved) {
      await Navigator.of(context).maybePop();
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
    if (_specs.isEmpty) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(
          child: Text(
            'This item cannot be edited.',
            style: TextStyle(color: LeopardColors.textMuted),
          ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(
          '${_base == null ? 'NEW' : 'EDIT'} '
          '${itemTypeLabel(_type).toUpperCase()}',
        ),
        actions: [
          TextButton(
            key: const Key('item-save'),
            onPressed: _saving ? null : _save,
            child: Text(_saving ? 'SAVING…' : 'SAVE'),
          ),
        ],
      ),
      body: WideBody(child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          for (final spec in _specs) ...[
            _field(spec),
            const SizedBox(height: 14),
          ],
          if (_type == CardItem.typeName)
            const Text(
              'The security code (CVV) is never stored.',
              style: TextStyle(fontSize: 12, color: LeopardColors.textMuted),
            ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            ErrorText(_error!),
          ],
        ],
      )),
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
          IconButton(
            key: const Key('edit-generate'),
            tooltip: 'Generate password',
            icon: const Icon(Icons.casino_outlined),
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
