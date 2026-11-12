import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:leopard_core/leopard_core.dart';
import 'package:leopard_ui/leopard_ui.dart';

import '../../../core/widgets/feedback.dart';
import 'activity_cubit.dart';
import 'sessions_page.dart' show formatTimestamp;
import '../../../core/widgets/page_scaffold.dart';
import '../../../core/widgets/tokens.dart';

/// Readable names of the audit events of docs/api.md.
const Map<String, String> auditEventLabels = {
  'vault_setup': 'Vault created',
  'setup_denied': 'Setup attempt refused',
  'device_auth_ok': 'Phone signed in',
  'device_auth_failed': 'Phone sign-in failed',
  'qr_created': 'Web login started',
  'qr_approved': 'Web login approved',
  'qr_approve_failed': 'Web login approval failed',
  'qr_rejected': 'Web login rejected',
  'qr_consumed': 'Web login completed',
  'master_login_ok': 'Signed in with master password',
  'master_login_failed': 'Master password sign-in failed',
  'recovery_device_registered': 'New phone registered with recovery key',
  'recovery_failed': 'Recovery attempt failed',
  'session_revoked': 'Session signed out',
  'session_expired': 'Session expired',
  'logout': 'Signed out',
  'item_deleted': 'Item deleted',
};

bool _isAlarming(String event) =>
    event.endsWith('_failed') ||
    event == 'setup_denied' ||
    event == 'recovery_device_registered';

/// The server's audit log. Needs an [ActivityCubit] above it.
class ActivityPage extends StatelessWidget {
  const ActivityPage({super.key});

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<ActivityCubit>();
    return Scaffold(
      appBar: AppBar(title: const Text('Activity log')),
      body: BlocBuilder<ActivityCubit, ActivityState>(
        builder: (context, state) {
          if (!state.loaded && state.message == null) {
            return const Center(child: CircularProgressIndicator());
          }
          return RefreshIndicator(
            color: LeopardColors.primary,
            backgroundColor: LeopardColors.surfaceHigh,
            onRefresh: cubit.load,
            child: ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                if (state.message != null)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: ErrorText(state.message!),
                  ),
                if (state.loaded && state.entries.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Text(
                      'Nothing has been recorded yet.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: LeopardColors.textMuted),
                    ),
                  ),
                if (state.entries.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: CardGroup(
                      children: [
                        for (final entry in state.entries)
                          _EntryTile(entry: entry),
                      ],
                    ),
                  ),
                if (state.hasMore)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: OutlinedButton(
                      key: const Key('activity-more'),
                      onPressed: state.loading ? null : cubit.loadMore,
                      child: Text(state.loading ? 'Loading…' : 'Older'),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry});

  final AuditEntry entry;

  @override
  Widget build(BuildContext context) {
    final alarming = _isAlarming(entry.event);
    final ip = entry.ip;
    return ListTile(
      key: Key('audit-${entry.id}'),
      leading: Icon(
        alarming ? Icons.warning_amber_outlined : Icons.circle_outlined,
        size: alarming ? 22 : 12,
        color: alarming ? warningColor : LeopardColors.textMuted,
      ),
      title: Text(auditEventLabels[entry.event] ?? entry.event),
      subtitle: Text(
        '${formatTimestamp(entry.timestamp)}'
        '${ip == null || ip.isEmpty ? '' : ' · $ip'}',
        style: const TextStyle(color: LeopardColors.textMuted),
      ),
    );
  }
}
