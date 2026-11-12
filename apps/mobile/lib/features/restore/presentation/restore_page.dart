import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:leopard_ui/leopard_ui.dart';

import '../../../core/widgets/feedback.dart';
import '../../../core/widgets/page_scaffold.dart';
import '../../../core/widgets/screen_lock_warning.dart';
import '../../../core/widgets/secret_text_field.dart';
import 'restore_cubit.dart';
import '../../../core/widgets/tokens.dart';

/// "Lost phone": registers this phone for an existing vault with the paper
/// recovery key. Needs a [RestoreCubit] above it.
class RestorePage extends StatelessWidget {
  const RestorePage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<RestoreCubit, RestoreState>(
      builder: (context, state) {
        // Once the server has accepted the key there is no way back: the
        // other phones are already signed out.
        final canLeave = !state.busy && state.step == RestoreStep.form;
        return PopScope(
          canPop: canLeave,
          child: Scaffold(
            appBar: AppBar(
              automaticallyImplyLeading: canLeave,
              title: Text(
                state.step == RestoreStep.form
                    ? 'Restore with recovery key'
                    : 'Vault restored',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              bottom: PreferredSize(
                preferredSize: const Size.fromHeight(2),
                child: LinearProgressIndicator(
                  value: state.busy ? null : _progress(state.step),
                  minHeight: 2,
                  backgroundColor: LeopardColors.divider,
                ),
              ),
            ),
            body: switch (state.step) {
              RestoreStep.form => _FormStep(state: state),
              RestoreStep.done => _DoneStep(state: state),
            },
          ),
        );
      },
    );
  }

  static double _progress(RestoreStep step) => switch (step) {
    RestoreStep.form => 0.5,
    RestoreStep.done => 1,
  };
}

class _FormStep extends StatefulWidget {
  const _FormStep({required this.state});

  final RestoreState state;

  @override
  State<_FormStep> createState() => _FormStepState();
}

class _FormStepState extends State<_FormStep> {
  final _url = TextEditingController(text: 'https://');
  final _label = TextEditingController(text: 'Android phone');
  final _recoveryKey = TextEditingController();
  final _password = TextEditingController();
  final _confirmation = TextEditingController();

  @override
  void dispose() {
    // The controllers hold the recovery key and the master password; empty
    // them before they go.
    _recoveryKey.clear();
    _password.clear();
    _confirmation.clear();
    _url.dispose();
    _label.dispose();
    _recoveryKey.dispose();
    _password.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  void _submit() => context.read<RestoreCubit>().submit(
    serverUrl: _url.text,
    deviceLabel: _label.text,
    recoveryKey: _recoveryKey.text,
    masterPassword: _password.text,
    confirmation: _confirmation.text,
  );

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    return PageBody(
      children: [
        const Text(
          'Lost or replaced your phone? The recovery key you wrote down at '
          'setup moves your vault to this phone.',
          style: TextStyle(color: LeopardColors.textMuted),
        ),
        const SizedBox(height: 16),
        const Panel(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LeopardIcon(
                LeopardIcons.shieldAlert,
                size: 20,
                color: LeopardColors.primary,
              ),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Restoring signs out every other phone and every web '
                  'session. The old phone will no longer reach the server.',
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        const ScreenLockWarning(),
        TextField(
          key: const Key('restore-server-url'),
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
          key: const Key('restore-device-label'),
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
        TextField(
          key: const Key('restore-recovery-key'),
          controller: _recoveryKey,
          enabled: !state.busy,
          style: leopardSecretTextStyle.copyWith(
            fontSize: 18,
            letterSpacing: 1.5,
          ),
          textCapitalization: TextCapitalization.characters,
          autocorrect: false,
          enableSuggestions: false,
          enableIMEPersonalizedLearning: false,
          autofillHints: null,
          smartDashesType: SmartDashesType.disabled,
          keyboardType: TextInputType.visiblePassword,
          maxLength: 40,
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9 \-]')),
          ],
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
            labelText: 'Recovery key',
            hintText: 'XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XX',
            helperText: 'Spaces, dashes and lower case are fine',
            counterText: '',
          ),
        ),
        const SizedBox(height: 16),
        SecretTextField(
          key: const Key('restore-password'),
          controller: _password,
          label: 'Master password',
          helperText: 'The password of this vault, chosen at setup',
          enabled: !state.busy,
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 16),
        SecretTextField(
          key: const Key('restore-password-confirm'),
          controller: _confirmation,
          label: 'Repeat master password',
          enabled: !state.busy,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: 8),
        const Text(
          'This phone uses the master password when it has no screen lock, '
          'and whenever you choose to unlock with it. The server cannot '
          'check it here, so type it exactly.',
          style: TextStyle(color: LeopardColors.textMuted, fontSize: 12),
        ),
        if (state.error != null) ...[
          const SizedBox(height: 16),
          ErrorText(state.error!),
        ],
        const SizedBox(height: 24),
        FilledButton(
          key: const Key('restore-submit'),
          onPressed: state.busy ? null : _submit,
          child: Text(state.busy ? 'Restoring…' : 'Restore vault'),
        ),
        if (state.busy) ...[
          const SizedBox(height: 12),
          const Text(
            'Registering this phone, then deriving the key from your '
            'password. This takes a few seconds on purpose.',
            textAlign: TextAlign.center,
            style: TextStyle(color: LeopardColors.textMuted, fontSize: 12),
          ),
        ],
      ],
    );
  }
}

class _DoneStep extends StatelessWidget {
  const _DoneStep({required this.state});

  final RestoreState state;

  @override
  Widget build(BuildContext context) {
    return PageBody(
      children: [
        const SizedBox(height: 8),
        const BrandHeader(subtitle: 'Your vault is on this phone.'),
        const SizedBox(height: 28),
        const Panel(
          key: Key('restore-old-phone-notice'),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LeopardIcon(
                LeopardIcons.unlock,
                size: 20,
                color: LeopardColors.ok,
              ),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Your old phone has been disconnected from the server. '
                  'Every other phone and every web session were signed out.',
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        const Panel(
          key: Key('restore-vk-notice'),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LeopardIcon(
                LeopardIcons.shieldAlert,
                size: 20,
                color: warningColor,
              ),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  'The vault key was not changed. If the old phone was '
                  'stolen while unlocked, or someone else may have seen '
                  'your recovery key, treat the stored passwords as exposed '
                  'and change the important ones.',
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'Your recovery key still works. Keep the paper copy safe.',
          style: TextStyle(color: LeopardColors.textMuted),
        ),
        if (state.error != null) ...[
          const SizedBox(height: 16),
          ErrorText(state.error!),
        ],
        const SizedBox(height: 24),
        FilledButton(
          key: const Key('restore-open'),
          onPressed: state.busy ? null : context.read<RestoreCubit>().openVault,
          child: const Text('Open vault'),
        ),
      ],
    );
  }
}
