import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:leopard_ui/leopard_ui.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../core/widgets/feedback.dart';
import '../../../core/widgets/page_scaffold.dart';
import '../../../core/widgets/secret_text_field.dart';
import '../../../core/widgets/tokens.dart';
import '../domain/qr_login_repository.dart';
import 'qr_approve_cubit.dart';

/// Builds the camera view; calls `onCode` with the text of each QR code.
typedef QrScannerBuilder =
    Widget Function(BuildContext context, ValueChanged<String> onCode);

Widget _cameraScanner(BuildContext context, ValueChanged<String> onCode) =>
    _CameraScanner(onCode: onCode);

/// Scan a browser's login QR code and approve or reject it.
///
/// Needs a [QrApproveCubit] above it.
class QrApprovePage extends StatelessWidget {
  const QrApprovePage({super.key, this.scannerBuilder = _cameraScanner});

  /// Replaced in widget tests, where there is no camera.
  final QrScannerBuilder scannerBuilder;

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<QrApproveCubit>();
    return BlocBuilder<QrApproveCubit, QrApproveState>(
      builder: (context, state) {
        final reviewing = switch (state.status) {
          QrApproveStatus.review ||
          QrApproveStatus.authenticating ||
          QrApproveStatus.passwordRequired ||
          QrApproveStatus.verifyingPassword ||
          QrApproveStatus.submitting => true,
          _ => false,
        };
        return Scaffold(
          appBar: AppBar(
            leading: const CloseButton(),
            title: reviewing ? null : const Text('Approve web login'),
          ),
          body: switch (state.status) {
            QrApproveStatus.scanning => Column(
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 8, 20, 16),
                  child: Text(
                    'Point the camera at the QR code shown on the Leopard '
                    'web page.',
                    style: TextStyle(
                      color: LeopardColors.textMuted,
                      fontSize: 15,
                      height: 1.5,
                    ),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(24),
                      child: scannerBuilder(context, cubit.scanned),
                    ),
                  ),
                ),
              ],
            ),
            QrApproveStatus.loading => const Center(
              child: CircularProgressIndicator(),
            ),
            QrApproveStatus.review ||
            QrApproveStatus.authenticating ||
            QrApproveStatus.passwordRequired ||
            QrApproveStatus.verifyingPassword ||
            QrApproveStatus.submitting => _Review(state: state),
            QrApproveStatus.approved => _Outcome(
              icon: Icons.verified_outlined,
              color: LeopardColors.ok,
              title: 'Login approved',
              message:
                  'The browser is being signed in. The session ends after 5 '
                  'minutes without activity, and you can end it at any time '
                  'under Security › Sessions.',
              action: 'Done',
              onAction: () => Navigator.of(context).maybePop(),
            ),
            QrApproveStatus.rejected => _Outcome(
              icon: Icons.block,
              color: LeopardColors.textMuted,
              title: 'Login rejected',
              message: 'Nothing was sent to the browser.',
              action: 'Done',
              onAction: () => Navigator.of(context).maybePop(),
            ),
            QrApproveStatus.expired || QrApproveStatus.failed => _Outcome(
              icon: Icons.error_outline,
              color: LeopardColors.danger,
              title: state.status == QrApproveStatus.expired
                  ? 'Request expired'
                  : 'Not approved',
              message: state.message ?? 'The login was not approved.',
              action: 'Scan again',
              onAction: cubit.scanAgain,
            ),
          },
        );
      },
    );
  }
}

class _Review extends StatelessWidget {
  const _Review({required this.state});

  final QrApproveState state;

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<QrApproveCubit>();
    final QrLoginRequest request = state.request!;
    final idle = state.status == QrApproveStatus.review;
    final code = request.verifyCode;
    final prompting =
        state.status == QrApproveStatus.passwordRequired ||
        state.status == QrApproveStatus.verifyingPassword;
    return SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: CustomScrollView(
            slivers: [
              SliverFillRemaining(
                hasScrollBody: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Sign in on the web?',
                        style: Theme.of(context).textTheme.headlineLarge
                            ?.copyWith(fontSize: 30, height: 1.15),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Approve only if you are signing in right now.',
                        style: TextStyle(
                          color: LeopardColors.textMuted,
                          fontSize: 15,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 24),
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: LeopardColors.surface,
                          borderRadius: BorderRadius.circular(24),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  width: 44,
                                  height: 44,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: LeopardColors.surfaceHigh,
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  child: const LeopardIcon(
                                    LeopardIcons.monitor,
                                    size: 22,
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        _orUnknown(
                                          [request.browser, request.platform]
                                              .where((s) => s.isNotEmpty)
                                              .join(' on '),
                                        ),
                                        style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Wrap(
                                        spacing: 6,
                                        children: [
                                          Text(
                                            _orUnknown(request.ip),
                                            key: const Key('qr-ip'),
                                            style: leopardSecretTextStyle
                                                .copyWith(
                                                  fontSize: 13,
                                                  letterSpacing: 0,
                                                  color:
                                                      LeopardColors.textMuted,
                                                ),
                                          ),
                                          Text(
                                            '· ${_time(request.createdAt)}',
                                            style: const TextStyle(
                                              fontSize: 13,
                                              color: LeopardColors.textMuted,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            if (request.userAgent.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              Text(
                                request.userAgent,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: LeopardColors.textMuted,
                                ),
                              ),
                            ],
                            const SizedBox(height: 16),
                            const Divider(),
                            const SizedBox(height: 16),
                            const Text(
                              'Code shown in the browser',
                              style: TextStyle(
                                fontSize: 13,
                                color: LeopardColors.textMuted,
                              ),
                            ),
                            const SizedBox(height: 16),
                            Center(
                              child: Text(
                                '${code.substring(0, 3)} ${code.substring(3)}',
                                key: const Key('qr-verify-code'),
                                textAlign: TextAlign.center,
                                style: leopardSecretTextStyle.copyWith(
                                  fontSize: 40,
                                  letterSpacing: 6,
                                  fontWeight: FontWeight.w600,
                                  color: LeopardColors.primary,
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),
                            _Countdown(
                              createdAt: request.createdAt,
                              expiresAt: request.expiresAt,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                        decoration: BoxDecoration(
                          color: noticeBackground,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: const Row(
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
                                _instruction,
                                key: Key('qr-instruction'),
                                style: TextStyle(
                                  color: noticeText,
                                  fontSize: 13,
                                  height: 1.5,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 4),
                        child: Text(
                          'Browser details are reported by the browser '
                          'itself and can be faked. The code is what counts.',
                          style: TextStyle(
                            fontSize: 12,
                            color: LeopardColors.textMuted,
                          ),
                        ),
                      ),
                      if (state.message != null) ...[
                        const SizedBox(height: 16),
                        ErrorText(state.message!),
                      ],
                      const Spacer(),
                      const SizedBox(height: 24),
                      if (prompting)
                        _PasswordPrompt(busy: state.busy)
                      else ...[
                        FilledButton.icon(
                          key: const Key('qr-approve'),
                          onPressed: idle ? cubit.approve : null,
                          style: _tallButton,
                          icon: const LeopardIcon(
                            LeopardIcons.unlock,
                            size: 20,
                            color: LeopardColors.onPrimary,
                          ),
                          label: Text(switch (state.status) {
                            QrApproveStatus.authenticating =>
                              'Waiting for screen lock…',
                            QrApproveStatus.submitting => 'Sending…',
                            _ => 'Approve with screen lock',
                          }),
                        ),
                        const SizedBox(height: 10),
                        OutlinedButton(
                          key: const Key('qr-reject'),
                          onPressed: idle ? cubit.reject : null,
                          style: _tallButton,
                          child: const Text('Reject'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static const String _instruction =
      'The codes must match. If they differ, or you did not start a login '
      'yourself, reject it: someone else may have sent you this QR.';

  static final ButtonStyle _tallButton = ButtonStyle(
    minimumSize: WidgetStateProperty.all(const Size.fromHeight(56)),
  );

  static String _orUnknown(String value) => value.isEmpty ? 'Unknown' : value;

  static String _time(DateTime time) {
    final t = time.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }
}

/// A bar that runs down to the moment the request expires, with the seconds
/// left. Display only: the cubit decides what an expired request means.
class _Countdown extends StatefulWidget {
  const _Countdown({required this.createdAt, required this.expiresAt});

  final DateTime createdAt;
  final DateTime expiresAt;

  @override
  State<_Countdown> createState() => _CountdownState();
}

class _CountdownState extends State<_Countdown> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.expiresAt.difference(widget.createdAt).inMilliseconds;
    final left = widget.expiresAt.difference(DateTime.now()).inMilliseconds;
    final fraction = total <= 0 ? 0.0 : (left / total).clamp(0, 1).toDouble();
    final seconds = left <= 0 ? 0 : (left / 1000).ceil();
    return Row(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              key: const Key('qr-countdown'),
              value: fraction,
              minHeight: 4,
              color: LeopardColors.primary,
              backgroundColor: LeopardColors.divider,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Text(
          '$seconds s',
          style: const TextStyle(fontSize: 12, color: LeopardColors.textMuted),
        ),
      ],
    );
  }
}

/// Asked instead of the screen-lock prompt on a phone that has no screen
/// lock.
class _PasswordPrompt extends StatefulWidget {
  const _PasswordPrompt({required this.busy});

  final bool busy;

  @override
  State<_PasswordPrompt> createState() => _PasswordPromptState();
}

class _PasswordPromptState extends State<_PasswordPrompt> {
  final _password = TextEditingController();

  @override
  void dispose() {
    _password.clear();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final password = _password.text;
    _password.clear();
    await context.read<QrApproveCubit>().approveWithPassword(password);
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<QrApproveCubit>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SecretTextField(
          key: const Key('qr-password'),
          controller: _password,
          label: 'Master password',
          enabled: !widget.busy,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: 16),
        FilledButton(
          key: const Key('qr-password-submit'),
          onPressed: widget.busy ? null : _submit,
          style: _Review._tallButton,
          child: Text(
            widget.busy ? 'Checking…' : 'Approve with master password',
          ),
        ),
        const SizedBox(height: 10),
        OutlinedButton(
          key: const Key('qr-password-cancel'),
          onPressed: widget.busy ? null : cubit.cancelPassword,
          style: _Review._tallButton,
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

class _Outcome extends StatelessWidget {
  const _Outcome({
    required this.icon,
    required this.color,
    required this.title,
    required this.message,
    required this.action,
    required this.onAction,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String message;
  final String action;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) => PageBody(
    children: [
      const SizedBox(height: 48),
      Icon(icon, size: 56, color: color),
      const SizedBox(height: 16),
      Text(
        title,
        key: const Key('qr-outcome-title'),
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.headlineSmall,
      ),
      const SizedBox(height: 12),
      Text(
        message,
        textAlign: TextAlign.center,
        style: const TextStyle(color: LeopardColors.textMuted),
      ),
      const SizedBox(height: 32),
      OutlinedButton(
        key: const Key('qr-outcome-action'),
        onPressed: onAction,
        child: Text(action),
      ),
    ],
  );
}

class _CameraScanner extends StatefulWidget {
  const _CameraScanner({required this.onCode});

  final ValueChanged<String> onCode;

  @override
  State<_CameraScanner> createState() => _CameraScannerState();
}

class _CameraScannerState extends State<_CameraScanner> {
  final MobileScannerController _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value != null && value.isNotEmpty) {
        widget.onCode(value);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) => MobileScanner(
    controller: _controller,
    onDetect: _onDetect,
    errorBuilder: (context, error) => Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          error.errorCode == MobileScannerErrorCode.permissionDenied
              ? 'Leopard needs the camera to scan the login code. Allow '
                    'camera access in the system settings.'
              : 'The camera could not be started.',
          textAlign: TextAlign.center,
          style: const TextStyle(color: LeopardColors.textMuted),
        ),
      ),
    ),
  );
}
