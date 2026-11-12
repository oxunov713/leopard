import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:leopard_core/leopard_core.dart';
import 'package:leopard_ui/leopard_ui.dart';

import '../../../core/security/password_handoff.dart';
import '../../../core/security/secret_clipboard.dart';
import '../../../core/widgets/feedback.dart';
import '../../../core/widgets/strength_meter.dart';
import '../../../core/widgets/ui_parts.dart';
import 'generator_cubit.dart';

/// Password and passphrase generator. Needs a [GeneratorCubit] above it.
///
/// The generator works without a login: it only needs the browser's random
/// number generator. Saving the result as an item needs the vault, so that
/// button is shown only when [canSave] is set; signed out, the page has its
/// own top bar with the way back to the login instead.
class GeneratorPage extends StatelessWidget {
  const GeneratorPage({super.key, this.canSave = true});

  /// Whether the vault is unlocked.
  final bool canSave;

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
    final body = BlocBuilder<GeneratorCubit, GeneratorState>(
      builder: (context, state) => _body(context, state),
    );
    if (canSave) {
      return body;
    }
    return PublicPage(
      action: FilledButton(
        key: const Key('generator-to-login'),
        onPressed: () => context.go('/login'),
        child: const Text('Sign in'),
      ),
      child: body,
    );
  }

  Widget _body(BuildContext context, GeneratorState state) {
    final cubit = context.read<GeneratorCubit>();
    final small = MediaQuery.sizeOf(context).width < HomeBreakpoints.rail;
    final padding = small ? 20.0 : 40.0;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(padding, small ? 20 : 32, padding, 32),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Password generator',
                style: headingStyle(28, letterSpacing: -0.4),
              ),
              const SizedBox(height: 4),
              const Text(
                'Made in this browser. Nothing is sent anywhere.',
                style: TextStyle(fontSize: 13, color: LeopardColors.textMuted),
              ),
              const SizedBox(height: 24),
              CardPanel(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Plain Text on purpose: a selectable value could be
                    // copied with Ctrl+C, bypassing the 30 s clipboard clear
                    // of the Copy button.
                    Text(
                      state.value,
                      key: const Key('generator-value'),
                      style: leopardSecretTextStyle.copyWith(fontSize: 22),
                    ),
                    const SizedBox(height: 16),
                    StrengthMeter(bits: state.entropyBits),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  OutlinedButton.icon(
                    key: const Key('generator-regenerate'),
                    onPressed: cubit.regenerate,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('New'),
                  ),
                  FilledButton.icon(
                    key: const Key('generator-copy'),
                    onPressed: () => copySecret(
                      context,
                      context.read<SecretClipboard>(),
                      state.value,
                    ),
                    icon: const LeopardIcon(LeopardIcons.copy, size: 18),
                    label: const Text('Copy'),
                  ),
                  if (canSave)
                    OutlinedButton.icon(
                      key: const Key('generator-save'),
                      onPressed: () {
                        context.read<PasswordHandoff>().offer(state.value);
                        context.go('/vault/new/${LoginItem.typeName}');
                      },
                      icon: const LeopardIcon(LeopardIcons.plus, size: 18),
                      label: const Text('Save as new item'),
                    ),
                ],
              ),
              const SizedBox(height: 24),
              CardPanel(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
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
                      onSelectionChanged: (selection) =>
                          cubit.setMode(selection.first),
                    ),
                    const SizedBox(height: 12),
                    if (state.mode == GeneratorMode.password) ...[
                      _SliderRow(
                        label: 'Length',
                        value: state.length,
                        min: GeneratorCubit.minLength,
                        max: GeneratorCubit.maxLength,
                        onChanged: cubit.setLength,
                      ),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final entry in _classLabels.entries)
                            FilterChip(
                              key: Key('generator-class-${entry.key.name}'),
                              label: Text(
                                entry.value,
                                style: leopardSecretTextStyle.copyWith(
                                  fontSize: 13,
                                ),
                              ),
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
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final entry in _separators.entries)
                            ChoiceChip(
                              label: Text(entry.value),
                              selected: state.separator == entry.key,
                              showCheckmark: false,
                              onSelected: (_) =>
                                  cubit.setSeparator(entry.key),
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
            ],
          ),
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
        child: Text(
          '$value',
          textAlign: TextAlign.end,
          style: leopardSecretTextStyle,
        ),
      ),
    ],
  );
}
