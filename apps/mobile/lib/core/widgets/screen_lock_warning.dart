import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:leopard_ui/leopard_ui.dart';

import '../security/device_authenticator.dart';
import 'tokens.dart';

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
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
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
                'This phone has no screen lock. Leopard will ask for your '
                'master password every time you open it or approve a web '
                'login, and the vault is only as safe as the phone is '
                'physically. Set a PIN, pattern or password in Android '
                'settings (a fingerprint or face is optional).',
                style: TextStyle(color: noticeText, fontSize: 13, height: 1.5),
              ),
            ),
          ],
        ),
      );
    },
  );
}
