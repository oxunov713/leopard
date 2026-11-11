import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../app/theme.dart';
import '../security/device_authenticator.dart';

/// A notice that shows only on a phone without a screen lock.
///
/// Leopard uses the screen lock (PIN, pattern or password; a biometric is
/// optional) to guard the vault. Without one, the master password is asked
/// every time, and anybody who picks the phone up has nothing else in the way
/// of the stored keys. Needs a [DeviceAuthenticator] repository above it.
class ScreenLockWarning extends StatefulWidget {
  const ScreenLockWarning({super.key});

  @override
  State<ScreenLockWarning> createState() => _ScreenLockWarningState();
}

class _ScreenLockWarningState extends State<ScreenLockWarning> {
  late final Future<DeviceLockStatus> _status = context
      .read<DeviceAuthenticator>()
      .lockStatus();

  @override
  Widget build(BuildContext context) => FutureBuilder<DeviceLockStatus>(
    future: _status,
    builder: (context, snapshot) {
      if (snapshot.data != DeviceLockStatus.none) {
        return const SizedBox.shrink();
      }
      return Container(
        key: const Key('screen-lock-warning'),
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(color: LeopardColors.brass),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.warning_amber_rounded, color: LeopardColors.brass),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                'This phone has no screen lock. Leopard will ask for your '
                'master password every time you open it or approve a web '
                'login, and the vault is only as safe as the phone is '
                'physically. Set a PIN, pattern or password in Android '
                'settings (a fingerprint or face is optional).',
              ),
            ),
          ],
        ),
      );
    },
  );
}
