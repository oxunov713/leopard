import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:leopard_ui/leopard_ui.dart';

import '../../../core/widgets/feedback.dart';
import '../../../core/widgets/secret_text_field.dart';
import '../../../core/widgets/ui_parts.dart';
import '../domain/emergency_login_repository.dart';
import 'emergency_login_cubit.dart';

/// Login without the phone: master password and a code from the
/// authenticator app. Needs an [EmergencyLoginCubit] above it.
class EmergencyLoginPage extends StatefulWidget {
  const EmergencyLoginPage({super.key});

  @override
  State<EmergencyLoginPage> createState() => _EmergencyLoginPageState();
}

class _EmergencyLoginPageState extends State<EmergencyLoginPage> {
  final TextEditingController _password = TextEditingController();
  final TextEditingController _code = TextEditingController();

  @override
  void dispose() {
    _password
      ..clear()
      ..dispose();
    _code
      ..clear()
      ..dispose();
    super.dispose();
  }

  void _submit() {
    context.read<EmergencyLoginCubit>().submit(
      masterPassword: _password.text,
      totpCode: _code.text,
    );
  }

  static String _phaseText(EmergencyLoginPhase? phase) => switch (phase) {
    null || EmergencyLoginPhase.fetchingParameters => 'Contacting the server…',
    EmergencyLoginPhase.derivingKey => 'Deriving the key from your password…',
    EmergencyLoginPhase.verifying => 'Checking with the server…',
  };

  @override
  Widget build(BuildContext context) =>
      BlocConsumer<EmergencyLoginCubit, EmergencyLoginState>(
        listenWhen: (before, after) =>
            before.isWorking && !after.isWorking && after.error != null,
        // A code is single-use: whatever went wrong, the next attempt needs
        // a new one.
        listener: (context, state) => _code.clear(),
        builder: (context, state) => PublicPage(
          action: TextButton(
            key: const Key('emergency-back'),
            onPressed: state.isWorking ? null : () => context.go('/login'),
            child: const Text('Back to the QR code'),
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Column(
                  children: [
                    CardPanel(
                      radius: 28,
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            'Sign in with master password',
                            style: headingStyle(24, letterSpacing: -0.3),
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            'Emergency login without the phone.',
                            style: TextStyle(
                              fontSize: 14,
                              color: LeopardColors.textMuted,
                            ),
                          ),
                          const SizedBox(height: 24),
                          SecretTextField(
                            key: const Key('emergency-password'),
                            controller: _password,
                            label: 'Master password',
                            autofocus: true,
                            enabled: !state.isWorking,
                            textInputAction: TextInputAction.next,
                          ),
                          const SizedBox(height: 14),
                          TextField(
                            key: const Key('emergency-code'),
                            controller: _code,
                            enabled: !state.isWorking,
                            style: leopardSecretTextStyle,
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                              LengthLimitingTextInputFormatter(6),
                            ],
                            autocorrect: false,
                            enableSuggestions: false,
                            enableIMEPersonalizedLearning: false,
                            autofillHints: null,
                            textInputAction: TextInputAction.done,
                            onSubmitted: (_) => _submit(),
                            decoration: const InputDecoration(
                              labelText: 'Authenticator code',
                              helperText:
                                  '6 digits, from the app you set up with '
                                  'Leopard',
                            ),
                          ),
                          const SizedBox(height: 24),
                          if (state.isWorking)
                            _Working(
                              text: _phaseText(state.phase),
                              phase: state.phase,
                              elapsedSeconds: state.elapsedSeconds,
                            )
                          else
                            FilledButton(
                              key: const Key('emergency-submit'),
                              onPressed: state.canSubmit ? _submit : null,
                              child: Text(
                                state.canSubmit
                                    ? 'Unlock'
                                    : 'Wait ${state.retryInSeconds} s',
                              ),
                            ),
                          if (state.error != null) ...[
                            const SizedBox(height: 16),
                            ErrorText(
                              state.error!,
                              key: const Key('emergency-error'),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      'The password never leaves this browser. It is turned '
                      'into a key here (Argon2id, 64 MiB), which takes '
                      'several seconds and may make the page stutter. The '
                      'server allows 5 attempts in 15 minutes.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        color: LeopardColors.textMuted,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
}

class _Working extends StatelessWidget {
  const _Working({
    required this.text,
    required this.phase,
    required this.elapsedSeconds,
  });

  final String text;
  final EmergencyLoginPhase? phase;
  final int elapsedSeconds;

  @override
  Widget build(BuildContext context) => Column(
    key: const Key('emergency-working'),
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const LinearProgressIndicator(minHeight: 3),
      const SizedBox(height: 12),
      Text(text, textAlign: TextAlign.center),
      if (phase == EmergencyLoginPhase.derivingKey) ...[
        const SizedBox(height: 4),
        Text(
          '$elapsedSeconds s · keep this tab open',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12, color: LeopardColors.textMuted),
        ),
      ],
    ],
  );
}
