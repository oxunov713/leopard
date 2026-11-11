import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../app/theme.dart';
import '../../../core/security/secret_clipboard.dart';
import '../../../core/widgets/feedback.dart';
import '../../../core/widgets/page_scaffold.dart';
import '../../../core/widgets/screen_lock_warning.dart';
import '../../../core/widgets/secret_text_field.dart';
import '../domain/setup_repository.dart';
import 'setup_cubit.dart';

/// First-run wizard. Needs a [SetupCubit] above it.
class SetupPage extends StatelessWidget {
  const SetupPage({super.key});

  static const List<String> _titles = [
    'Server',
    'Master password',
    'Recovery key',
    'Check recovery key',
    'Authenticator',
    'Done',
  ];

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<SetupCubit, SetupState>(
      builder: (context, state) {
        final cubit = context.read<SetupCubit>();
        final canGoBack =
            !state.busy &&
            state.step != SetupStep.server &&
            state.step != SetupStep.done;
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop && canGoBack) cubit.back();
          },
          child: Scaffold(
            appBar: AppBar(
              automaticallyImplyLeading: false,
              leading: canGoBack
                  ? IconButton(
                      tooltip: 'Back',
                      icon: const Icon(Icons.arrow_back),
                      onPressed: cubit.back,
                    )
                  : null,
              title: Text(
                'Set up · ${state.step.index.clamp(0, 4) + 1} of 5 · '
                '${_titles[state.step.index]}',
              ),
              bottom: PreferredSize(
                preferredSize: const Size.fromHeight(2),
                child: LinearProgressIndicator(
                  value: state.busy ? null : (state.step.index + 1) / 5,
                  minHeight: 2,
                  backgroundColor: LeopardColors.outline,
                ),
              ),
            ),
            body: switch (state.step) {
              SetupStep.server => _ServerStep(state: state),
              SetupStep.password => _PasswordStep(state: state),
              SetupStep.recoveryKey => _RecoveryKeyStep(state: state),
              SetupStep.recoveryCheck => _RecoveryCheckStep(state: state),
              SetupStep.totp => _TotpStep(state: state),
              SetupStep.done => const Center(
                child: CircularProgressIndicator(),
              ),
            },
          ),
        );
      },
    );
  }
}

class _ServerStep extends StatefulWidget {
  const _ServerStep({required this.state});

  final SetupState state;

  @override
  State<_ServerStep> createState() => _ServerStepState();
}

class _ServerStepState extends State<_ServerStep> {
  final _url = TextEditingController(text: 'https://');
  final _label = TextEditingController(text: 'Android phone');
  final _token = TextEditingController();

  @override
  void dispose() {
    _url.dispose();
    _label.dispose();
    _token.dispose();
    super.dispose();
  }

  void _submit() => context.read<SetupCubit>().submitServer(
    serverUrl: _url.text,
    deviceLabel: _label.text,
    setupToken: _token.text,
  );

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    return PageBody(
      children: [
        const SizedBox(height: 8),
        const LeopardMark(subtitle: 'Your vault. Your keys.'),
        const SizedBox(height: 28),
        const Text(
          'This phone will hold the keys to your vault. The server only '
          'ever stores encrypted data.',
          style: TextStyle(color: LeopardColors.textMuted),
        ),
        const SizedBox(height: 20),
        const ScreenLockWarning(),
        TextField(
          key: const Key('setup-server-url'),
          controller: _url,
          enabled: !state.busy,
          keyboardType: TextInputType.url,
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
            labelText: 'Server address',
            helperText: 'Must start with https://',
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          key: const Key('setup-device-label'),
          controller: _label,
          enabled: !state.busy,
          maxLength: 64,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
            labelText: 'Name of this phone',
            helperText: 'Shown in the list of sessions',
            counterText: '',
          ),
        ),
        const SizedBox(height: 16),
        SecretTextField(
          key: const Key('setup-token'),
          controller: _token,
          label: 'Setup token (optional)',
          helperText: 'Only if the server was started with LEOPARD_SETUP_TOKEN',
          enabled: !state.busy,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
        ),
        if (state.error != null) ...[
          const SizedBox(height: 16),
          ErrorText(state.error!),
        ],
        const SizedBox(height: 24),
        FilledButton(
          key: const Key('setup-server-continue'),
          onPressed: state.busy ? null : _submit,
          child: Text(state.busy ? 'CONTACTING SERVER…' : 'CONTINUE'),
        ),
      ],
    );
  }
}

class _PasswordStep extends StatefulWidget {
  const _PasswordStep({required this.state});

  final SetupState state;

  @override
  State<_PasswordStep> createState() => _PasswordStepState();
}

class _PasswordStepState extends State<_PasswordStep> {
  final _password = TextEditingController();
  final _confirmation = TextEditingController();

  @override
  void dispose() {
    // The controllers hold the master password; empty them before they go.
    _password.clear();
    _confirmation.clear();
    _password.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  void _submit() => context.read<SetupCubit>().submitPassword(
    password: _password.text,
    confirmation: _confirmation.text,
  );

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    return PageBody(
      children: [
        const Text(
          'The master password protects your vault if the server is ever '
          'breached, and lets you sign in on the web without this phone. '
          'It cannot be reset or changed later. A sentence of several '
          'unrelated words works well.',
          style: TextStyle(color: LeopardColors.textMuted),
        ),
        const SizedBox(height: 20),
        SecretTextField(
          key: const Key('setup-password'),
          controller: _password,
          label: 'Master password',
          enabled: !state.busy,
          autofocus: true,
          textInputAction: TextInputAction.next,
          onChanged: context.read<SetupCubit>().passwordChanged,
        ),
        const SizedBox(height: 12),
        StrengthMeter(bits: state.passwordBits, problem: state.passwordProblem),
        const SizedBox(height: 16),
        SecretTextField(
          key: const Key('setup-password-confirm'),
          controller: _confirmation,
          label: 'Repeat master password',
          enabled: !state.busy,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
        ),
        if (state.error != null) ...[
          const SizedBox(height: 16),
          ErrorText(state.error!),
        ],
        const SizedBox(height: 24),
        FilledButton(
          key: const Key('setup-password-continue'),
          onPressed: state.busy ? null : _submit,
          child: Text(state.busy ? 'GENERATING KEYS…' : 'CONTINUE'),
        ),
        if (state.busy) ...[
          const SizedBox(height: 12),
          const Text(
            'Deriving the key from your password. This takes a few seconds '
            'on purpose.',
            textAlign: TextAlign.center,
            style: TextStyle(color: LeopardColors.textMuted, fontSize: 12),
          ),
        ],
      ],
    );
  }
}

/// Strength bar for a password being typed.
class StrengthMeter extends StatelessWidget {
  const StrengthMeter({super.key, required this.bits, this.problem});

  final double bits;

  /// Why the password is not acceptable yet; `null` when it is.
  final String? problem;

  static const double _fullScaleBits = 100;

  @override
  Widget build(BuildContext context) {
    final acceptable = bits > 0 && problem == null;
    final (label, color) = switch (bits) {
      <= 0 => ('', LeopardColors.outline),
      < 40 => ('Weak', LeopardColors.danger),
      < MasterPasswordPolicy.minBits => ('Fair', LeopardColors.warning),
      < 80 => ('Strong', LeopardColors.ok),
      _ => ('Very strong', LeopardColors.ok),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(
            value: (bits / _fullScaleBits).clamp(0, 1).toDouble(),
            minHeight: 6,
            color: acceptable ? color : (bits > 0 ? color : null),
            backgroundColor: LeopardColors.outline,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          bits <= 0
              ? 'At least ${MasterPasswordPolicy.minLength} characters.'
              : '$label · about ${bits.round()} bits'
                    '${problem == null ? '' : ' · $problem'}',
          key: const Key('strength-label'),
          style: TextStyle(
            fontSize: 12,
            color: problem == null ? LeopardColors.textMuted : color,
          ),
        ),
      ],
    );
  }
}

class _RecoveryKeyStep extends StatelessWidget {
  const _RecoveryKeyStep({required this.state});

  final SetupState state;

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<SetupCubit>();
    return PageBody(
      children: [
        const Text(
          'Write this recovery key on paper and keep it somewhere safe. '
          'It is the only way to move your vault to a new phone if this '
          'one is lost. It is shown once and never stored.',
          style: TextStyle(color: LeopardColors.textMuted),
        ),
        const SizedBox(height: 20),
        Panel(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
          child: Wrap(
            alignment: WrapAlignment.center,
            spacing: 14,
            runSpacing: 14,
            children: [
              for (final (index, group) in state.recoveryGroups.indexed)
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${index + 1}',
                      style: const TextStyle(
                        fontSize: 10,
                        color: LeopardColors.textMuted,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      group,
                      style: secretTextStyle.copyWith(
                        fontSize: 22,
                        letterSpacing: 2,
                        color: LeopardColors.brass,
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'Do not take a screenshot or a photo, and do not keep it in a '
          'notes app.',
          style: TextStyle(color: LeopardColors.textMuted, fontSize: 12),
        ),
        const SizedBox(height: 12),
        CheckboxListTile(
          key: const Key('setup-recovery-ack'),
          value: state.recoveryAcknowledged,
          onChanged: (value) => cubit.acknowledgeRecoveryKey(value ?? false),
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
          title: const Text('I wrote it down'),
        ),
        if (state.error != null) ...[
          const SizedBox(height: 8),
          ErrorText(state.error!),
        ],
        const SizedBox(height: 16),
        FilledButton(
          key: const Key('setup-recovery-continue'),
          onPressed: state.recoveryAcknowledged
              ? cubit.continueFromRecoveryKey
              : null,
          child: const Text('CONTINUE'),
        ),
      ],
    );
  }
}

class _RecoveryCheckStep extends StatefulWidget {
  const _RecoveryCheckStep({required this.state});

  final SetupState state;

  @override
  State<_RecoveryCheckStep> createState() => _RecoveryCheckStepState();
}

class _RecoveryCheckStepState extends State<_RecoveryCheckStep> {
  late final List<TextEditingController> _answers = [
    for (final _ in widget.state.challengeGroups) TextEditingController(),
  ];

  @override
  void dispose() {
    for (final controller in _answers) {
      controller.dispose();
    }
    super.dispose();
  }

  void _submit() => context.read<SetupCubit>().submitRecoveryCheck([
    for (final controller in _answers) controller.text,
  ]);

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    return PageBody(
      children: [
        const Text(
          'To make sure the recovery key was written down correctly, type '
          'two of its groups from your paper copy.',
          style: TextStyle(color: LeopardColors.textMuted),
        ),
        const SizedBox(height: 20),
        for (final (i, group) in state.challengeGroups.indexed) ...[
          TextField(
            key: Key('setup-recovery-group-$i'),
            controller: _answers[i],
            style: secretTextStyle.copyWith(fontSize: 20, letterSpacing: 2),
            textCapitalization: TextCapitalization.characters,
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
            autofillHints: null,
            keyboardType: TextInputType.visiblePassword,
            maxLength: 4,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp('[A-Za-z2-7]')),
            ],
            textInputAction: i + 1 == state.challengeGroups.length
                ? TextInputAction.done
                : TextInputAction.next,
            onSubmitted: i + 1 == state.challengeGroups.length
                ? (_) => _submit()
                : null,
            decoration: InputDecoration(
              labelText: 'Group ${group + 1}',
              counterText: '',
            ),
          ),
          const SizedBox(height: 16),
        ],
        if (state.error != null) ...[
          ErrorText(state.error!),
          const SizedBox(height: 16),
        ],
        FilledButton(
          key: const Key('setup-recovery-check-continue'),
          onPressed: _submit,
          child: const Text('CONTINUE'),
        ),
      ],
    );
  }
}

class _TotpStep extends StatefulWidget {
  const _TotpStep({required this.state});

  final SetupState state;

  @override
  State<_TotpStep> createState() => _TotpStepState();
}

class _TotpStepState extends State<_TotpStep> {
  final _code = TextEditingController();

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  void _submit() => context.read<SetupCubit>().submitTotpCode(_code.text);

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    return PageBody(
      children: [
        const Text(
          'Signing in on the web without this phone needs your master '
          'password and a code from an authenticator app. Scan this code '
          'with an authenticator on another device, or type the secret '
          'into it, then enter the 6-digit code it shows.',
          style: TextStyle(color: LeopardColors.textMuted),
        ),
        const SizedBox(height: 20),
        Center(
          child: Container(
            color: Colors.white,
            padding: const EdgeInsets.all(8),
            child: QrImageView(
              key: const Key('setup-totp-qr'),
              data: state.totpUri,
              size: 200,
              backgroundColor: Colors.white,
              errorCorrectionLevel: QrErrorCorrectLevel.M,
            ),
          ),
        ),
        const SizedBox(height: 16),
        Panel(
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _grouped(state.totpSecret),
                  key: const Key('setup-totp-secret'),
                  style: secretTextStyle,
                ),
              ),
              IconButton(
                tooltip: 'Copy secret',
                icon: const Icon(Icons.copy_outlined),
                onPressed: () => copySecret(
                  context,
                  context.read<SecretClipboard>(),
                  state.totpSecret,
                  what: 'Secret copied',
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        TextField(
          key: const Key('setup-totp-code'),
          controller: _code,
          enabled: !state.busy,
          style: secretTextStyle.copyWith(fontSize: 24, letterSpacing: 6),
          textAlign: TextAlign.center,
          keyboardType: TextInputType.number,
          autocorrect: false,
          enableSuggestions: false,
          enableIMEPersonalizedLearning: false,
          autofillHints: null,
          maxLength: 6,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          onSubmitted: (_) => _submit(),
          decoration: const InputDecoration(
            labelText: 'Code from the authenticator',
            counterText: '',
          ),
        ),
        if (state.error != null) ...[
          const SizedBox(height: 16),
          ErrorText(state.error!),
        ],
        const SizedBox(height: 24),
        FilledButton(
          key: const Key('setup-finish'),
          onPressed: state.busy ? null : _submit,
          child: Text(state.busy ? 'CREATING VAULT…' : 'CREATE VAULT'),
        ),
      ],
    );
  }

  static String _grouped(String secret) {
    final out = StringBuffer();
    for (var i = 0; i < secret.length; i += 4) {
      if (i > 0) out.write(' ');
      out.write(
        secret.substring(i, i + 4 > secret.length ? secret.length : i + 4),
      );
    }
    return out.toString();
  }
}
