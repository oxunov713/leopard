import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../core/lock/app_lock_cubit.dart';
import '../../../core/widgets/feedback.dart';
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
      confirmLabel: 'REMOVE',
      destructive: true,
    );
    if (ok && context.mounted) {
      await context.read<AppLockCubit>().eraseDevice();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('SECURITY')),
      body: ListView(
        children: [
          const SectionLabel('Web access'),
          ListTile(
            key: const Key('security-scan'),
            leading: const Icon(Icons.qr_code_scanner),
            title: const Text('Approve a web login'),
            subtitle: const Text('Scan the QR code shown in the browser'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/scan'),
          ),
          const Divider(indent: 56),
          ListTile(
            key: const Key('security-sessions'),
            leading: const Icon(Icons.devices_other),
            title: const Text('Sessions'),
            subtitle: const Text('See and sign out active sessions'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/sessions'),
          ),
          const Divider(indent: 56),
          ListTile(
            key: const Key('security-activity'),
            leading: const Icon(Icons.receipt_long_outlined),
            title: const Text('Activity log'),
            subtitle: const Text('Logins, approvals and deletions'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/activity'),
          ),
          const SectionLabel('This phone'),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: ScreenLockWarning(),
          ),
          ListTile(
            key: const Key('security-lock'),
            leading: const Icon(Icons.lock_outline),
            title: const Text('Lock now'),
            subtitle: const Text(
              'Locks by itself after 30 seconds in the background',
            ),
            onTap: context.read<AppLockCubit>().lock,
          ),
          const Divider(indent: 56),
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
    );
  }
}
