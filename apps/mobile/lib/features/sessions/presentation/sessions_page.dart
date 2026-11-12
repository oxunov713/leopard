import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:leopard_core/leopard_core.dart';
import 'package:leopard_ui/leopard_ui.dart';

import '../../../core/widgets/feedback.dart';
import 'sessions_cubit.dart';
import '../../../core/widgets/page_scaffold.dart';

String formatTimestamp(DateTime time) {
  final t = time.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} '
      '${two(t.hour)}:${two(t.minute)}';
}

/// What a session's client says about itself. Untrusted, display only.
String describeClient(Map<String, Object?> clientInfo) {
  final reported = clientInfo['reported'];
  final parts = <String>[];
  if (reported is Map<String, Object?>) {
    for (final key in const ['browser', 'platform']) {
      final value = reported[key];
      if (value is String && value.trim().isNotEmpty) {
        parts.add(value.trim());
      }
    }
  }
  if (parts.isEmpty) {
    final agent = clientInfo['user_agent'];
    if (agent is String && agent.trim().isNotEmpty) {
      parts.add(agent.trim());
    }
  }
  final text = parts.join(' on ').replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ');
  return text.length > 120 ? '${text.substring(0, 120)}…' : text;
}

/// Active sessions. Needs a [SessionsCubit] above it.
class SessionsPage extends StatelessWidget {
  const SessionsPage({super.key});

  Future<void> _revokeAll(BuildContext context) async {
    final ok = await confirm(
      context,
      title: 'Sign out all web sessions?',
      message: 'Every browser signed in to your vault is signed out now.',
      confirmLabel: 'Sign out all',
      destructive: true,
    );
    if (ok && context.mounted) {
      await context.read<SessionsCubit>().revokeAllWeb();
    }
  }

  Future<void> _revoke(BuildContext context, SessionInfo session) async {
    final ok = await confirm(
      context,
      title: session.current ? 'Sign out this phone?' : 'Sign out session?',
      message: session.current
          ? 'This is the session of this phone. It signs in again by '
                'itself the next time it talks to the server.'
          : 'The session is ended immediately.',
      confirmLabel: 'Sign out',
      destructive: true,
    );
    if (ok && context.mounted) {
      await context.read<SessionsCubit>().revoke(session.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<SessionsCubit>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sessions'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: cubit.load,
          ),
        ],
      ),
      body: BlocConsumer<SessionsCubit, SessionsState>(
        listenWhen: (before, after) =>
            after.message != null && before.message != after.message,
        listener: (context, state) => showMessage(context, state.message!),
        builder: (context, state) {
          if (state.status == SessionsStatus.loading) {
            return const Center(child: CircularProgressIndicator());
          }
          return RefreshIndicator(
            color: LeopardColors.primary,
            backgroundColor: LeopardColors.surfaceHigh,
            onRefresh: cubit.load,
            child: ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: OutlinedButton.icon(
                    key: const Key('sessions-revoke-all-web'),
                    onPressed: state.busy || state.webSessionCount == 0
                        ? null
                        : () => _revokeAll(context),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: LeopardColors.danger,
                      side: const BorderSide(color: LeopardColors.danger),
                    ),
                    icon: const Icon(Icons.logout),
                    label: Text(
                      'Sign out all web sessions (${state.webSessionCount})',
                    ),
                  ),
                ),
                if (state.status == SessionsStatus.failure)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: ErrorText(
                      state.message ?? 'The sessions could not be loaded.',
                    ),
                  ),
                if (state.sessions.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: CardGroup(
                      children: [
                        for (final session in state.sessions)
                          ListTile(
                            key: Key('session-${session.id}'),
                            isThreeLine: true,
                            leading: Icon(
                              session.kind == SessionKind.web
                                  ? Icons.language
                                  : Icons.smartphone,
                              color: session.current
                                  ? LeopardColors.primary
                                  : null,
                            ),
                            title: Text(
                              session.kind == SessionKind.web
                                  ? 'Web${_clientSuffix(session)}'
                                  : session.current
                                  ? 'This phone'
                                  : 'Phone',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '${session.ip.isEmpty ? 'Unknown address' : session.ip}\n'
                              'Last seen ${formatTimestamp(session.lastSeen)}',
                              style: const TextStyle(
                                color: LeopardColors.textMuted,
                              ),
                            ),
                            trailing: IconButton(
                              key: Key('session-revoke-${session.id}'),
                              tooltip: 'Sign out',
                              icon: const Icon(Icons.logout),
                              onPressed: state.busy
                                  ? null
                                  : () => _revoke(context, session),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  static String _clientSuffix(SessionInfo session) {
    final client = describeClient(session.clientInfo);
    return client.isEmpty ? '' : ' · $client';
  }
}
