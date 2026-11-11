import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:leopard_core/leopard_core.dart';

import '../../../app/theme.dart';
import '../../../core/security/secret_clipboard.dart';
import '../../../core/widgets/feedback.dart';
import '../../../core/widgets/page_scaffold.dart';
import 'generator_cubit.dart';

/// Password and passphrase generator. Needs a [GeneratorCubit] above it.
class GeneratorPage extends StatelessWidget {
  const GeneratorPage({super.key});

  static const Map<CharClass, String> _classLabels = {
    CharClass.lowercase: 'a-z',
    CharClass.uppercase: 'A-Z',
    CharClass.digits: '0-9',
    CharClass.symbols: '!@#',
  };

  static const Map<String, String> _separators = {
    '-': 'Hyphen',
    ' ': 'Space',
    '.': 'Dot',
    '_': 'Underscore',
  };

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<GeneratorCubit>();
    return Scaffold(
      appBar: AppBar(title: const Text('GENERATOR')),
      body: BlocBuilder<GeneratorCubit, GeneratorState>(
        builder: (context, state) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            Panel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(
                    state.value,
                    key: const Key('generator-value'),
                    style: secretTextStyle.copyWith(fontSize: 19),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '${state.entropyBits.round()} bits of entropy',
                    key: const Key('generator-entropy'),
                    style: const TextStyle(
                      fontSize: 12,
                      color: LeopardColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('generator-regenerate'),
                    onPressed: cubit.regenerate,
                    icon: const Icon(Icons.refresh),
                    label: const Text('NEW'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('generator-copy'),
                    onPressed: () => copySecret(
                      context,
                      context.read<SecretClipboard>(),
                      state.value,
                    ),
                    icon: const Icon(Icons.copy_outlined),
                    label: const Text('COPY'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const Key('generator-save'),
              onPressed: () => context.push(
                '/vault/new/${LoginItem.typeName}',
                extra: state.value,
              ),
              icon: const Icon(Icons.add),
              label: const Text('SAVE AS NEW ITEM'),
            ),
            const SizedBox(height: 20),
            SegmentedButton<GeneratorMode>(
              segments: const [
                ButtonSegment(
                  value: GeneratorMode.password,
                  label: Text('Password'),
                ),
                ButtonSegment(
                  value: GeneratorMode.passphrase,
                  label: Text('Passphrase'),
                ),
              ],
              selected: {state.mode},
              showSelectedIcon: false,
              onSelectionChanged: (selection) => cubit.setMode(selection.first),
            ),
            const SizedBox(height: 8),
            if (state.mode == GeneratorMode.password) ...[
              _SliderRow(
                label: 'Length',
                value: state.length,
                min: GeneratorCubit.minLength,
                max: GeneratorCubit.maxLength,
                onChanged: cubit.setLength,
              ),
              Wrap(
                spacing: 8,
                children: [
                  for (final entry in _classLabels.entries)
                    FilterChip(
                      key: Key('generator-class-${entry.key.name}'),
                      label: Text(entry.value, style: secretTextStyle),
                      selected: state.classes.contains(entry.key),
                      showCheckmark: false,
                      onSelected: (_) => cubit.toggleClass(entry.key),
                    ),
                ],
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Avoid look-alike characters'),
                subtitle: const Text('0 O o 1 l I |'),
                value: state.excludeAmbiguous,
                onChanged: cubit.setExcludeAmbiguous,
              ),
            ] else ...[
              _SliderRow(
                label: 'Words',
                value: state.wordCount,
                min: GeneratorCubit.minWords,
                max: GeneratorCubit.maxWords,
                onChanged: cubit.setWordCount,
              ),
              Wrap(
                spacing: 8,
                children: [
                  for (final entry in _separators.entries)
                    ChoiceChip(
                      label: Text(entry.value),
                      selected: state.separator == entry.key,
                      showCheckmark: false,
                      onSelected: (_) => cubit.setSeparator(entry.key),
                    ),
                ],
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Capitalise words'),
                value: state.capitalize,
                onChanged: cubit.setCapitalize,
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Add a digit'),
                value: state.includeNumber,
                onChanged: cubit.setIncludeNumber,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final String label;
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      SizedBox(width: 64, child: Text(label)),
      Expanded(
        child: Slider(
          value: value.toDouble(),
          min: min.toDouble(),
          max: max.toDouble(),
          divisions: max - min,
          label: '$value',
          onChanged: (v) => onChanged(v.round()),
        ),
      ),
      SizedBox(
        width: 32,
        child: Text('$value', textAlign: TextAlign.end, style: secretTextStyle),
      ),
    ],
  );
}
