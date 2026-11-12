import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leopard_mobile/app/theme.dart';
import 'package:leopard_mobile/core/lock/app_lock_cubit.dart';
import 'package:leopard_mobile/core/security/device_authenticator.dart';
import 'package:leopard_mobile/core/security/secret_clipboard.dart';
import 'package:leopard_mobile/features/qr_approve/presentation/qr_approve_cubit.dart';
import 'package:leopard_mobile/features/restore/presentation/restore_cubit.dart';
import 'package:leopard_mobile/features/setup/presentation/setup_cubit.dart';
import 'package:leopard_mobile/features/unlock/presentation/unlock_cubit.dart';
import 'package:leopard_mobile/features/vault/presentation/vault_cubit.dart';
import 'package:mocktail/mocktail.dart';

import '../support/fakes.dart';

class MockSetupCubit extends MockCubit<SetupState> implements SetupCubit {}

class MockRestoreCubit extends MockCubit<RestoreState>
    implements RestoreCubit {}

class MockUnlockCubit extends MockCubit<UnlockState> implements UnlockCubit {}

class MockVaultCubit extends MockCubit<VaultState> implements VaultCubit {}

class MockQrApproveCubit extends MockCubit<QrApproveState>
    implements QrApproveCubit {}

class MockAppLockCubit extends MockCubit<AppLockState>
    implements AppLockCubit {}

/// Makes [cubit] report [state] and emit nothing else.
void givenState<S>(MockCubit<S> cubit, S state) {
  whenListen(cubit, Stream<S>.empty(), initialState: state);
}

/// A tall phone-sized surface, so that whole pages are laid out and every
/// button can be tapped without scrolling.
void useTallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 3200);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
}

/// Pumps [page] inside the app's theme with a clipboard double and a
/// [DeviceAuthenticator] (screen lock set, unless [lockStatus] says otherwise)
/// above it.
Future<MockSecretClipboard> pumpPage(
  WidgetTester tester,
  Widget page, {
  List<BlocProvider<dynamic>> providers = const [],
  DeviceLockStatus lockStatus = DeviceLockStatus.secured,
}) async {
  useTallSurface(tester);
  // Start from an empty tree: a BlocBuilder kept from an earlier pump in
  // the same test would go on showing the state it already had.
  await tester.pumpWidget(const SizedBox());
  final clipboard = MockSecretClipboard();
  when(() => clipboard.copy(any())).thenAnswer((_) async {});
  when(clipboard.clearNow).thenAnswer((_) async {});
  final deviceAuth = MockDeviceAuthenticator();
  when(deviceAuth.lockStatus).thenAnswer((_) async => lockStatus);
  final app = MaterialApp(theme: buildLeopardTheme(), home: page);
  await tester.pumpWidget(
    MultiRepositoryProvider(
      providers: [
        RepositoryProvider<SecretClipboard>.value(value: clipboard),
        RepositoryProvider<DeviceAuthenticator>.value(value: deviceAuth),
      ],
      child: providers.isEmpty
          ? app
          : MultiBlocProvider(providers: providers, child: app),
    ),
  );
  return clipboard;
}

/// The [TextField] inside the widget with [key].
TextField textFieldOf(WidgetTester tester, Key key) => tester.widget<TextField>(
  find.descendant(
    of: find.byKey(key),
    matching: find.byType(TextField),
    matchRoot: true,
  ),
);
