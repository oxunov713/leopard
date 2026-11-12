import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../core/security/password_handoff.dart';
import '../core/security/secret_clipboard.dart';
import '../core/session/session_cubit.dart';
import '../features/vault/presentation/vault_cubit.dart';
import 'dependencies.dart';
import 'router.dart';
import 'theme.dart';

/// The root widget: providers, the router, and the three things that feed
/// the session rules — user activity, tab visibility and tab close.
class LeopardApp extends StatefulWidget {
  const LeopardApp({super.key, required this.dependencies});

  final AppDependencies dependencies;

  @override
  State<LeopardApp> createState() => _LeopardAppState();
}

class _LeopardAppState extends State<LeopardApp> {
  late final SessionCubit _session;
  late final VaultCubit _vault;
  late final GoRouter _router;
  late final AppLifecycleListener _lifecycle;
  late final StreamSubscription<SessionState> _sessionSubscription;
  SessionStatus _status = SessionStatus.signedOut;

  @override
  void initState() {
    super.initState();
    final deps = widget.dependencies;
    _session = SessionCubit(
      session: deps.session,
      api: deps.api,
      clipboard: deps.clipboard,
      now: deps.now,
    );
    _vault = VaultCubit(deps.vaultRepository);
    _router = buildRouter(session: _session, dependencies: deps);
    // Decrypted items follow the session: loaded on login, dropped the
    // moment it ends (crypto-spec §11).
    _sessionSubscription = _session.stream.listen((state) {
      if (state.status == _status) return;
      _status = state.status;
      if (state.status == SessionStatus.unlocked) {
        unawaited(_vault.load());
      } else {
        _vault.clear();
        deps.passwordHandoff.clear();
      }
    });
    // In a browser `hidden` is the tab going to the background
    // (`visibilitychange`) and `detached` is the page being unloaded.
    _lifecycle = AppLifecycleListener(
      onHide: _session.onHidden,
      onShow: _session.onVisible,
      onDetach: _session.onPageClosing,
    );
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  /// Every key event counts as activity. Never consumes the event.
  bool _onKey(KeyEvent event) {
    _session.recordActivity();
    return false;
  }

  void _onPointer(PointerEvent event) => _session.recordActivity();

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _lifecycle.dispose();
    unawaited(_sessionSubscription.cancel());
    _router.dispose();
    unawaited(_vault.close());
    unawaited(_session.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiRepositoryProvider(
      providers: [
        RepositoryProvider<SecretClipboard>.value(
          value: widget.dependencies.clipboard,
        ),
        RepositoryProvider<PasswordHandoff>.value(
          value: widget.dependencies.passwordHandoff,
        ),
      ],
      child: MultiBlocProvider(
        providers: [
          BlocProvider<SessionCubit>.value(value: _session),
          BlocProvider<VaultCubit>.value(value: _vault),
        ],
        // Pointer presses, movement and scrolling anywhere in the page are
        // activity. The listener only observes; it takes part in no gesture.
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: _onPointer,
          onPointerMove: _onPointer,
          onPointerHover: _onPointer,
          onPointerSignal: _onPointer,
          child: MaterialApp.router(
            title: 'Leopard',
            debugShowCheckedModeBanner: false,
            theme: buildLeopardTheme(),
            darkTheme: buildLeopardTheme(),
            themeMode: ThemeMode.dark,
            routerConfig: _router,
          ),
        ),
      ),
    );
  }
}

/// Shown instead of the app when the build has no usable API address.
class ConfigErrorApp extends StatelessWidget {
  const ConfigErrorApp({super.key, required this.problem});

  final String problem;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Leopard',
    debugShowCheckedModeBanner: false,
    theme: buildLeopardTheme(),
    home: Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.settings_suggest_outlined,
                  size: 40,
                  color: LeopardColors.textMuted,
                ),
                const SizedBox(height: 16),
                Text(problem, textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
