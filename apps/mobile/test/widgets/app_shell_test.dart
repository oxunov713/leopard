import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leopard_mobile/app/router.dart';
import 'package:leopard_mobile/app/theme.dart';
import 'package:leopard_mobile/core/lock/app_lock_cubit.dart';

void main() {
  group('redirectFor: vault screens exist only while unlocked', () {
    const vaultRoutes = [
      '/vault',
      '/vault/item/0f8fad5b-d9cb-469f-a165-70867728950e',
      '/vault/edit/0f8fad5b-d9cb-469f-a165-70867728950e',
      '/vault/new/login',
      '/generator',
      '/health',
      '/security',
      '/scan',
      '/sessions',
      '/activity',
    ];

    test('locked: everything goes to the lock screen', () {
      for (final route in [...vaultRoutes, '/', '/setup']) {
        expect(redirectFor(AppLockStatus.locked, route), '/unlock');
      }
      expect(redirectFor(AppLockStatus.locked, '/unlock'), isNull);
    });

    test('no vault on this phone: everything goes to setup', () {
      for (final route in [...vaultRoutes, '/', '/unlock']) {
        expect(redirectFor(AppLockStatus.needsSetup, route), '/setup');
      }
      expect(redirectFor(AppLockStatus.needsSetup, '/setup'), isNull);
    });

    test('unlocked: entry screens lead to the vault, the rest stay', () {
      for (final route in ['/', '/setup', '/unlock']) {
        expect(redirectFor(AppLockStatus.unlocked, route), '/vault');
      }
      for (final route in vaultRoutes) {
        expect(redirectFor(AppLockStatus.unlocked, route), isNull);
      }
    });

    test('starting or storage error: only the start screen', () {
      for (final status in [
        AppLockStatus.starting,
        AppLockStatus.storageError,
      ]) {
        expect(redirectFor(status, '/'), isNull);
        for (final route in vaultRoutes) {
          expect(redirectFor(status, route), '/');
        }
      }
    });
  });

  group('theme', () {
    test('dark only, near-black background, brass accent', () {
      final theme = buildLeopardTheme();
      expect(theme.brightness, Brightness.dark);
      expect(theme.colorScheme.brightness, Brightness.dark);
      expect(theme.scaffoldBackgroundColor, LeopardColors.background);
      expect(
        LeopardColors.background.computeLuminance(),
        lessThan(0.01),
        reason: 'near-black',
      );
      expect(theme.colorScheme.primary, LeopardColors.brass);
    });

    test('secrets are set in a monospace face', () {
      expect(secretTextStyle.fontFamily, 'monospace');
    });
  });
}
