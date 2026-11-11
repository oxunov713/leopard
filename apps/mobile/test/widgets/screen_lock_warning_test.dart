import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leopard_mobile/core/security/device_authenticator.dart';
import 'package:leopard_mobile/core/widgets/screen_lock_warning.dart';

import 'support.dart';

void main() {
  testWidgets('shows on a phone without a screen lock', (tester) async {
    await pumpPage(
      tester,
      const Scaffold(body: ScreenLockWarning()),
      lockStatus: DeviceLockStatus.none,
    );
    await tester.pump();
    expect(find.byKey(const Key('screen-lock-warning')), findsOneWidget);
    expect(find.textContaining('no screen lock'), findsOneWidget);
  });

  testWidgets('stays away when the phone has a screen lock', (tester) async {
    await pumpPage(tester, const Scaffold(body: ScreenLockWarning()));
    await tester.pump();
    expect(find.byKey(const Key('screen-lock-warning')), findsNothing);
  });
}
