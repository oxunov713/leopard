import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:leopard_ui/leopard_ui.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../core/session/session_cubit.dart';
import '../../../core/widgets/ui_parts.dart';
import 'qr_login_cubit.dart';

/// The QR tile is light so that phone cameras read it on the dark page.
const Color _qrTile = Color(0xFFF4F1EA);
const Color _qrInk = Color(0xFF141413);

/// The start page: log in by scanning a QR code with the phone.
/// Needs a [QrLoginCubit] above it.
class LoginPage extends StatelessWidget {
  const LoginPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Column(
        children: [
          PublicTopBar(
            trailing: OutlinedButton.icon(
              key: const Key('login-generator'),
              onPressed: () => context.go('/login/generator'),
              icon: const LeopardIcon(LeopardIcons.generator, size: 18),
              label: const Text('Password generator'),
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 900;
                return SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 48,
                  ),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: math.max(0, constraints.maxHeight - 96),
                    ),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 960),
                        child: wide
                            ? const Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  Expanded(child: _Intro(wide: true)),
                                  SizedBox(width: 48),
                                  SizedBox(width: 380, child: _QrCard()),
                                ],
                              )
                            : Column(
                                children: [
                                  const _Intro(wide: false),
                                  const SizedBox(height: 40),
                                  ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 380,
                                    ),
                                    child: const _QrCard(),
                                  ),
                                ],
                              ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}

class _Intro extends StatelessWidget {
  const _Intro({required this.wide});

  final bool wide;

  static const List<String> _steps = [
    'Open Leopard on your phone',
    'Tap Web login and scan this code',
    'Check both screens show the same 6 digits',
  ];

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      const SignOutNotice(),
      Text(
        'Open your vault\nwith your phone',
        style: headingStyle(
          wide ? 44 : 36,
          letterSpacing: -1,
        ).copyWith(height: 1.1),
      ),
      const SizedBox(height: 24),
      for (var i = 0; i < _steps.length; i++) ...[
        if (i > 0) const SizedBox(height: 16),
        Row(
          children: [
            Container(
              width: 32,
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: LeopardColors.surfaceHigh,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                '${i + 1}',
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  color: LeopardColors.primary,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(_steps[i], style: const TextStyle(fontSize: 16)),
            ),
          ],
        ),
      ],
      const SizedBox(height: 24),
      const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.only(top: 1),
            child: LeopardIcon(
              LeopardIcons.shieldAlert,
              size: 18,
              color: LeopardColors.textMuted,
            ),
          ),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'Nothing is saved in this browser. The vault locks after 5 '
              'minutes idle.',
              style: TextStyle(fontSize: 14, color: LeopardColors.textMuted),
            ),
          ),
        ],
      ),
      const SizedBox(height: 16),
      TextButton(
        key: const Key('login-emergency'),
        onPressed: () => context.go('/login/emergency'),
        style: TextButton.styleFrom(
          padding: EdgeInsets.zero,
          alignment: Alignment.centerLeft,
          minimumSize: const Size(0, 32),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
        ),
        child: const Text(
          'Lost your phone? Sign in with master password + code',
        ),
      ),
    ],
  );
}

/// Says why the browser is back on the login page, if it was signed out.
class SignOutNotice extends StatelessWidget {
  const SignOutNotice({super.key});

  @override
  Widget build(BuildContext context) => BlocBuilder<SessionCubit, SessionState>(
    builder: (context, state) {
      final text = describeSignOut(state.reason);
      if (text == null) {
        return const SizedBox.shrink();
      }
      return Container(
        key: const Key('sign-out-notice'),
        margin: const EdgeInsets.only(bottom: 24),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: LeopardColors.surface,
          border: Border.all(color: LeopardColors.primaryContainer),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const LeopardIcon(
              LeopardIcons.clock,
              size: 20,
              color: LeopardColors.primary,
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(text)),
          ],
        ),
      );
    },
  );
}

class _QrCard extends StatelessWidget {
  const _QrCard();

  @override
  Widget build(BuildContext context) => BlocBuilder<QrLoginCubit, QrLoginState>(
    builder: (context, state) => CardPanel(
      radius: 28,
      padding: const EdgeInsets.all(32),
      child: _QrPanel(state: state),
    ),
  );
}

class _QrPanel extends StatelessWidget {
  const _QrPanel({required this.state});

  final QrLoginState state;

  static const double _size = 248;

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<QrLoginCubit>();
    switch (state.status) {
      case QrLoginStatus.starting:
        return const _Placeholder(child: CircularProgressIndicator());
      case QrLoginStatus.signedIn:
        return const _Placeholder(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LeopardIcon(
                LeopardIcons.unlock,
                color: LeopardColors.ok,
                size: 40,
              ),
              SizedBox(height: 12),
              Text('Approved. Opening the vault…'),
            ],
          ),
        );
      case QrLoginStatus.rejected:
        return _Ended(
          key: const Key('qr-rejected'),
          icon: LeopardIcons.shieldAlert,
          text: 'The request was rejected on the phone.',
          onRetry: cubit.start,
        );
      case QrLoginStatus.expired:
        return _Ended(
          key: const Key('qr-expired'),
          icon: LeopardIcons.clock,
          text: 'The code expired.',
          onRetry: cubit.start,
        );
      case QrLoginStatus.failed:
        return _Ended(
          key: const Key('qr-failed'),
          icon: LeopardIcons.shieldAlert,
          text: state.error ?? 'The login could not be started.',
          onRetry: cubit.start,
        );
      case QrLoginStatus.waiting:
        final code = state.verifyCode ?? '';
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: _size,
              height: _size,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: _qrTile,
                borderRadius: BorderRadius.circular(16),
              ),
              child: QrImageView(
                key: const Key('login-qr'),
                data: state.qrText ?? '',
                size: _size - 32,
                padding: EdgeInsets.zero,
                eyeStyle: const QrEyeStyle(
                  eyeShape: QrEyeShape.square,
                  color: _qrInk,
                ),
                dataModuleStyle: const QrDataModuleStyle(
                  dataModuleShape: QrDataModuleShape.square,
                  color: _qrInk,
                ),
                errorCorrectionLevel: QrErrorCorrectLevel.M,
                semanticsLabel: 'Login QR code',
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'Verification code',
              style: TextStyle(fontSize: 13, color: LeopardColors.textMuted),
            ),
            const SizedBox(height: 6),
            SelectionContainer.disabled(
              child: Text(
                code.length == 6
                    ? '${code.substring(0, 3)} ${code.substring(3)}'
                    : code,
                key: const Key('login-verify-code'),
                style: leopardSecretTextStyle.copyWith(
                  fontSize: 34,
                  letterSpacing: 5,
                  fontWeight: FontWeight.w600,
                  color: LeopardColors.primary,
                ),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: state.totalSeconds <= 0
                          ? 0
                          : (state.secondsLeft / state.totalSeconds).clamp(
                              0.0,
                              1.0,
                            ),
                      minHeight: 4,
                      backgroundColor: LeopardColors.divider,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  state.reconnecting
                      ? 'Connection problem. Retrying…'
                      : 'New code in ${state.secondsLeft} s',
                  key: const Key('login-countdown'),
                  style: TextStyle(
                    fontSize: 12,
                    color: state.reconnecting
                        ? warningColor
                        : LeopardColors.textMuted,
                  ),
                ),
              ],
            ),
          ],
        );
    }
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: _QrPanel._size,
    child: Center(child: child),
  );
}

class _Ended extends StatelessWidget {
  const _Ended({
    super.key,
    required this.icon,
    required this.text,
    required this.onRetry,
  });

  final LeopardIconData icon;
  final String text;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: _QrPanel._size),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        LeopardIcon(icon, color: LeopardColors.textMuted, size: 40),
        const SizedBox(height: 16),
        Text(text, textAlign: TextAlign.center),
        const SizedBox(height: 20),
        OutlinedButton(
          key: const Key('qr-new-code'),
          onPressed: onRetry,
          child: const Text('Show a new code'),
        ),
      ],
    ),
  );
}
