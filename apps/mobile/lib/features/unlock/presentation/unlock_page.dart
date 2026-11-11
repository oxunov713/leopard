import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../app/theme.dart';
import '../../../core/widgets/feedback.dart';
import '../../../core/widgets/page_scaffold.dart';
import '../../../core/widgets/secret_text_field.dart';
import 'unlock_cubit.dart';

/// The lock screen. Needs an [UnlockCubit] above it.
class UnlockPage extends StatefulWidget {
  const UnlockPage({super.key});

  @override
  State<UnlockPage> createState() => _UnlockPageState();
}

class _UnlockPageState extends State<UnlockPage> {
  final _password = TextEditingController();
  AppLifecycleListener? _lifecycle;

  @override
  void initState() {
    super.initState();
    // The app may have locked itself while in the background. The system
    // prompt must only be raised once the lock screen is actually visible.
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle == null || lifecycle == AppLifecycleState.resumed) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _start());
    } else {
      _lifecycle = AppLifecycleListener(onResume: _start);
    }
  }

  void _start() {
    if (mounted) {
      context.read<UnlockCubit>().start();
    }
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    _password.clear();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final password = _password.text;
    _password.clear();
    await context.read<UnlockCubit>().unlockWithMasterPassword(password);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: BlocBuilder<UnlockCubit, UnlockState>(
        builder: (context, state) {
          final cubit = context.read<UnlockCubit>();
          return PageBody(
            children: [
              const SizedBox(height: 48),
              const LeopardMark(subtitle: 'Vault locked'),
              const SizedBox(height: 40),
              if (state.canUseDeviceLock) ...[
                OutlinedButton.icon(
                  key: const Key('unlock-device'),
                  onPressed: state.busy
                      ? null
                      : cubit.unlockWithDeviceCredential,
                  icon: const Icon(Icons.phonelink_lock),
                  label: const Text('UNLOCK WITH SCREEN LOCK'),
                ),
                const SizedBox(height: 28),
                const Row(
                  children: [
                    Expanded(child: Divider()),
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        'OR',
                        style: TextStyle(
                          fontSize: 11,
                          letterSpacing: 2,
                          color: LeopardColors.textMuted,
                        ),
                      ),
                    ),
                    Expanded(child: Divider()),
                  ],
                ),
                const SizedBox(height: 28),
              ],
              SecretTextField(
                key: const Key('unlock-password'),
                controller: _password,
                label: 'Master password',
                enabled: !state.busy,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submit(),
              ),
              if (state.message != null) ...[
                const SizedBox(height: 16),
                ErrorText(state.message!),
              ],
              const SizedBox(height: 20),
              FilledButton(
                key: const Key('unlock-submit'),
                onPressed: state.busy ? null : _submit,
                child: Text(switch (state.status) {
                  UnlockStatus.deriving => 'CHECKING…',
                  UnlockStatus.authenticating => 'WAITING FOR SCREEN LOCK…',
                  _ => 'UNLOCK WITH MASTER PASSWORD',
                }),
              ),
              if (state.status == UnlockStatus.deriving) ...[
                const SizedBox(height: 16),
                const LinearProgressIndicator(minHeight: 2),
              ],
              if (state.hasNoScreenLock) ...[
                const SizedBox(height: 24),
                const Text(
                  'This phone has no screen lock, so Leopard asks for your '
                  'master password every time. Set a PIN, pattern or '
                  'password in Android settings to unlock faster.',
                  key: Key('unlock-no-screen-lock'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: LeopardColors.textMuted,
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}
