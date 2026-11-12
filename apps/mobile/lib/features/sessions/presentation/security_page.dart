import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:leopard_ui/leopard_ui.dart';

import '../../../core/lock/app_lock_cubit.dart';
import '../../../core/widgets/feedback.dart';
import '../../../core/widgets/page_scaffold.dart';
import '../../../core/widgets/screen_lock_warning.dart';

/// Entry points for everything about access: web login, sessions, the
/// audit log, locking and removing the vault from this phone.
class SecurityPage extends StatelessWidget {
  const SecurityPage({super.key});

  Future<void> _erase(BuildContext context) async {
    final ok = await confirm(
      context,
      title: 'Remove vault from this phone?',
      message:
          'The keys stored on this phone are erased. Your vault stays on '
          'the server, but this phone can only get back in with the '
          'recovery key. Make sure you have it.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (ok && context.mounted) {
      await context.read<AppLockCubit>().eraseDevice();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
          children: [
            const LargeTitle('Security'),
            const SectionLabel('Web access'),
            CardGroup(
              children: [
                ListTile(
                  key: const Key('security-scan'),
                  leading: const LeopardIcon(LeopardIcons.scan),
                  title: const Text('Approve a web login'),
                  subtitle: const Text('Scan the QR code shown in the browser'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push('/scan'),
                ),
                ListTile(
                  key: const Key('security-sessions'),
                  leading: const LeopardIcon(LeopardIcons.monitor),
                  title: const Text('Sessions'),
                  subtitle: const Text('See and sign out active sessions'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push('/sessions'),
                ),
                ListTile(
                  key: const Key('security-activity'),
                  leading: const LeopardIcon(LeopardIcons.clock),
                  title: const Text('Activity log'),
                  subtitle: const Text('Logins, approvals and deletions'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push('/activity'),
                ),
              ],
            ),
            const SectionLabel('This phone'),
            const ScreenLockWarning(),
            CardGroup(
              children: [
                ListTile(
                  key: const Key('security-lock'),
                  leading: const LeopardIcon(LeopardIcons.lock),
                  title: const Text('Lock now'),
                  subtitle: const Text(
                    'Locks by itself after 30 seconds in the background',
                  ),
                  onTap: context.read<AppLockCubit>().lock,
                ),
                ListTile(
                  key: const Key('security-erase'),
                  leading: const Icon(
                    Icons.phonelink_erase,
                    color: LeopardColors.danger,
                  ),
                  title: const Text(
                    'Remove vault from this phone',
                    style: TextStyle(color: LeopardColors.danger),
                  ),
                  onTap: () => _erase(context),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
