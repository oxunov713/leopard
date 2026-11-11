import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../app/theme.dart';
import '../../../core/widgets/feedback.dart';
import '../../../core/widgets/page_scaffold.dart';
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
    return Scaffold(
      appBar: AppBar(title: const Text('APPROVE WEB LOGIN')),
      body: BlocBuilder<QrApproveCubit, QrApproveState>(
        builder: (context, state) => switch (state.status) {
          QrApproveStatus.scanning => Column(
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Point the camera at the QR code shown on the Leopard '
                  'web page.',
                  style: TextStyle(color: LeopardColors.textMuted),
                ),
              ),
              Expanded(child: scannerBuilder(context, cubit.scanned)),
            ],
          ),
          QrApproveStatus.loading => const Center(
            child: CircularProgressIndicator(),
          ),
          QrApproveStatus.review ||
          QrApproveStatus.authenticating ||
          QrApproveStatus.submitting => _Review(state: state),
          QrApproveStatus.approved => _Outcome(
            icon: Icons.verified_outlined,
            color: LeopardColors.ok,
            title: 'Login approved',
            message:
                'The browser is being signed in. The session ends after 5 '
                'minutes without activity, and you can end it at any time '
                'under Security › Sessions.',
            action: 'DONE',
            onAction: () => Navigator.of(context).maybePop(),
          ),
          QrApproveStatus.rejected => _Outcome(
            icon: Icons.block,
            color: LeopardColors.textMuted,
            title: 'Login rejected',
            message: 'Nothing was sent to the browser.',
            action: 'DONE',
            onAction: () => Navigator.of(context).maybePop(),
          ),
          QrApproveStatus.expired || QrApproveStatus.failed => _Outcome(
            icon: Icons.error_outline,
            color: LeopardColors.danger,
            title: state.status == QrApproveStatus.expired
                ? 'Request expired'
                : 'Not approved',
            message: state.message ?? 'The login was not approved.',
            action: 'SCAN AGAIN',
            onAction: cubit.scanAgain,
          ),
        },
      ),
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
    return PageBody(
      children: [
        const Text(
          'MATCH THIS WITH THE BROWSER',
          key: Key('qr-instruction'),
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            letterSpacing: 2,
            fontWeight: FontWeight.w600,
            color: LeopardColors.brass,
          ),
        ),
        const SizedBox(height: 12),
        Panel(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Text(
            '${code.substring(0, 3)} ${code.substring(3)}',
            key: const Key('qr-verify-code'),
            textAlign: TextAlign.center,
            style: secretTextStyle.copyWith(
              fontSize: 48,
              letterSpacing: 6,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'Approve only if the browser in front of you shows exactly this '
          'code. If the codes differ, or you did not start a login '
          'yourself, reject.',
          textAlign: TextAlign.center,
          style: TextStyle(color: LeopardColors.textMuted),
        ),
        const SizedBox(height: 20),
        Panel(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              _DetailRow(
                label: 'Browser',
                value: _orUnknown(
                  [
                    request.browser,
                    request.platform,
                  ].where((s) => s.isNotEmpty).join(' on '),
                ),
              ),
              const Divider(),
              _DetailRow(
                key: const Key('qr-ip'),
                label: 'IP address',
                value: _orUnknown(request.ip),
                mono: true,
              ),
              const Divider(),
              _DetailRow(label: 'Requested', value: _time(request.createdAt)),
              if (request.userAgent.isNotEmpty) ...[
                const Divider(),
                _DetailRow(label: 'User agent', value: request.userAgent),
              ],
            ],
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Browser details are reported by the browser itself and can be '
          'faked. The code is what counts.',
          style: TextStyle(fontSize: 12, color: LeopardColors.textMuted),
        ),
        if (state.message != null) ...[
          const SizedBox(height: 16),
          ErrorText(state.message!),
        ],
        const SizedBox(height: 24),
        FilledButton.icon(
          key: const Key('qr-approve'),
          onPressed: idle ? cubit.approve : null,
          icon: const Icon(Icons.fingerprint),
          label: Text(switch (state.status) {
            QrApproveStatus.authenticating => 'WAITING FOR BIOMETRIC…',
            QrApproveStatus.submitting => 'SENDING…',
            _ => 'APPROVE',
          }),
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          key: const Key('qr-reject'),
          onPressed: idle ? cubit.reject : null,
          style: OutlinedButton.styleFrom(
            foregroundColor: LeopardColors.danger,
            side: const BorderSide(color: LeopardColors.danger),
          ),
          child: const Text('REJECT'),
        ),
      ],
    );
  }

  static String _orUnknown(String value) => value.isEmpty ? 'Unknown' : value;

  static String _time(DateTime time) {
    final t = time.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    super.key,
    required this.label,
    required this.value,
    this.mono = false,
  });

  final String label;
  final String value;
  final bool mono;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 96,
          child: Text(
            label,
            style: const TextStyle(color: LeopardColors.textMuted),
          ),
        ),
        Expanded(child: Text(value, style: mono ? secretTextStyle : null)),
      ],
    ),
  );
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
        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
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
