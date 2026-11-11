import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../core/lock/app_lock_cubit.dart';
import '../core/security/device_authenticator.dart';
import '../core/security/secret_clipboard.dart';
import '../features/vault/presentation/vault_cubit.dart';
import 'dependencies.dart';
import 'router.dart';
import 'theme.dart';

/// The root widget: providers, lifecycle-driven auto-lock and the router.
class LeopardApp extends StatefulWidget {
  const LeopardApp({super.key, required this.dependencies});

  final AppDependencies dependencies;

  @override
  State<LeopardApp> createState() => _LeopardAppState();
}

class _LeopardAppState extends State<LeopardApp> {
  late final AppLockCubit _lock;
  late final VaultCubit _vault;
  late final GoRouter _router;
  late final AppLifecycleListener _lifecycle;
  late final StreamSubscription<AppLockState> _lockSubscription;

  @override
  void initState() {
    super.initState();
    final deps = widget.dependencies;
    _lock = AppLockCubit(
      store: deps.deviceStore,
      session: deps.session,
      remote: deps.remote,
      clipboard: deps.clipboard,
    );
    _vault = VaultCubit(deps.vaultRepository);
    _router = buildRouter(lock: _lock, dependencies: deps);
    // Decrypted items follow the lock: loaded on unlock, dropped on lock.
    _lockSubscription = _lock.stream.listen((state) {
      if (state.status == AppLockStatus.unlocked) {
        unawaited(_vault.load());
      } else {
        _vault.clear();
      }
    });
    // `hidden` is the first state in which nothing of the app is visible;
    // a system dialog (screen-lock prompt, permission request) only makes it
    // `inactive` and does not start the auto-lock countdown.
    _lifecycle = AppLifecycleListener(
      onHide: _lock.onBackgrounded,
      onShow: _lock.onForegrounded,
    );
    unawaited(_lock.start());
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    unawaited(_lockSubscription.cancel());
    _router.dispose();
    unawaited(_vault.close());
    unawaited(_lock.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiRepositoryProvider(
      providers: [
        RepositoryProvider<SecretClipboard>.value(
          value: widget.dependencies.clipboard,
        ),
        RepositoryProvider<DeviceAuthenticator>.value(
          value: widget.dependencies.deviceAuthenticator,
        ),
      ],
      child: MultiBlocProvider(
        providers: [
          BlocProvider<AppLockCubit>.value(value: _lock),
          BlocProvider<VaultCubit>.value(value: _vault),
        ],
        child: MaterialApp.router(
          title: 'Leopard',
          debugShowCheckedModeBanner: false,
          theme: buildLeopardTheme(),
          darkTheme: buildLeopardTheme(),
          themeMode: ThemeMode.dark,
          routerConfig: _router,
        ),
      ),
    );
  }
}
