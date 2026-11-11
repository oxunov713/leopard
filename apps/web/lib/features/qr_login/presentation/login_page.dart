import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../app/theme.dart';
import '../../../core/session/session_cubit.dart';
import '../../../core/widgets/page_scaffold.dart';
import 'qr_login_cubit.dart';

/// The start page: log in by scanning a QR code with the phone.
/// Needs a [QrLoginCubit] above it.
class LoginPage extends StatelessWidget {
  const LoginPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    body: PageBody(
      children: [
        const SizedBox(height: 24),
        const LeopardMark(subtitle: 'Scan with the Leopard app to sign in'),
        const SizedBox(height: 24),
        const SignOutNotice(),
        BlocBuilder<QrLoginCubit, QrLoginState>(
          builder: (context, state) => Panel(
            padding: const EdgeInsets.all(24),
            child: _QrPanel(state: state),
          ),
        ),
        const SizedBox(height: 20),
        const Text(
          'On your phone: open Leopard, tap Security, then "Approve a web '
          'login", and scan this code. Approve only if the phone shows the '
          'same six digits.',
          textAlign: TextAlign.center,
          style: TextStyle(color: LeopardColors.textMuted, height: 1.4),
        ),
        const SizedBox(height: 20),
        Center(
          child: TextButton(
            key: const Key('login-emergency'),
            onPressed: () => context.go('/login/emergency'),
            child: const Text('No phone? Use the master password'),
          ),
        ),
        Center(
          child: TextButton(
            key: const Key('login-generator'),
            onPressed: () => context.go('/login/generator'),
            child: const Text('Password generator (no login needed)'),
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'This browser stores nothing. The vault key stays in memory and is '
          'erased after 5 minutes without activity.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: LeopardColors.textMuted),
        ),
      ],
    ),
  );
}

/// Says why the browser is back on the login page, if it was signed out.
class SignOutNotice extends StatelessWidget {
  const SignOutNotice({super.key});

  @override
  Widget build(BuildContext context) =>
      BlocBuilder<SessionCubit, SessionState>(
        builder: (context, state) {
          final text = describeSignOut(state.reason);
          if (text == null) {
            return const SizedBox.shrink();
          }
          return Container(
            key: const Key('sign-out-notice'),
            margin: const EdgeInsets.only(bottom: 16),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              border: Border.all(color: LeopardColors.brassDim),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.lock_clock_outlined,
                  size: 20,
                  color: LeopardColors.brass,
                ),
                const SizedBox(width: 12),
                Expanded(child: Text(text)),
              ],
            ),
          );
        },
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
              Icon(Icons.lock_open, color: LeopardColors.ok, size: 40),
              SizedBox(height: 12),
              Text('Approved. Opening the vault…'),
            ],
          ),
        );
      case QrLoginStatus.rejected:
        return _Ended(
          key: const Key('qr-rejected'),
          icon: Icons.block,
          text: 'The request was rejected on the phone.',
          onRetry: cubit.start,
        );
      case QrLoginStatus.expired:
        return _Ended(
          key: const Key('qr-expired'),
          icon: Icons.timer_off_outlined,
          text: 'The code expired.',
          onRetry: cubit.start,
        );
      case QrLoginStatus.failed:
        return _Ended(
          key: const Key('qr-failed'),
          icon: Icons.error_outline,
          text: state.error ?? 'The login could not be started.',
          onRetry: cubit.start,
        );
      case QrLoginStatus.waiting:
        final code = state.verifyCode ?? '';
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              color: Colors.white,
              padding: const EdgeInsets.all(8),
              child: QrImageView(
                key: const Key('login-qr'),
                data: state.qrText ?? '',
                size: _size - 16,
                padding: EdgeInsets.zero,
                backgroundColor: Colors.white,
                errorCorrectionLevel: QrErrorCorrectLevel.M,
                semanticsLabel: 'Login QR code',
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'VERIFICATION CODE',
              style: TextStyle(
                fontSize: 11,
                letterSpacing: 1.6,
                fontWeight: FontWeight.w600,
                color: LeopardColors.brass,
              ),
            ),
            const SizedBox(height: 6),
            SelectionContainer.disabled(
              child: Text(
                code.length == 6
                    ? '${code.substring(0, 3)} ${code.substring(3)}'
                    : code,
                key: const Key('login-verify-code'),
                style: secretTextStyle.copyWith(
                  fontSize: 34,
                  letterSpacing: 4,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: _size,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: state.totalSeconds <= 0
                      ? 0
                      : (state.secondsLeft / state.totalSeconds).clamp(
                          0.0,
                          1.0,
                        ),
                  minHeight: 3,
                  backgroundColor: LeopardColors.outline,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              state.reconnecting
                  ? 'Connection problem. Retrying…'
                  : 'New code in ${state.secondsLeft} s',
              key: const Key('login-countdown'),
              style: TextStyle(
                fontSize: 12,
                color: state.reconnecting
                    ? LeopardColors.warning
                    : LeopardColors.textMuted,
              ),
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
  Widget build(BuildContext context) =>
      SizedBox(height: _QrPanel._size, child: Center(child: child));
}

class _Ended extends StatelessWidget {
  const _Ended({
    super.key,
    required this.icon,
    required this.text,
    required this.onRetry,
  });

  final IconData icon;
  final String text;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: _QrPanel._size),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, color: LeopardColors.textMuted, size: 40),
        const SizedBox(height: 16),
        Text(text, textAlign: TextAlign.center),
        const SizedBox(height: 20),
        OutlinedButton(
          key: const Key('qr-new-code'),
          onPressed: onRetry,
          child: const Text('SHOW A NEW CODE'),
        ),
      ],
    ),
  );
}
