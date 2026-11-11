import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:leopard_core/leopard_core.dart';

import '../../../app/theme.dart';
import '../../../core/widgets/feedback.dart';
import '../../vault/presentation/vault_cubit.dart';
import 'health_cubit.dart';

/// Password health: weak, reused and old passwords.
///
/// Needs a [HealthCubit] and the [VaultCubit] above it. Re-runs the audit
/// whenever the vault changes.
class HealthPage extends StatefulWidget {
  const HealthPage({super.key});

  @override
  State<HealthPage> createState() => _HealthPageState();
}

class _HealthPageState extends State<HealthPage> {
  @override
  void initState() {
    super.initState();
    context.read<HealthCubit>().audit(context.read<VaultCubit>().state.entries);
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<VaultCubit, VaultState>(
      listenWhen: (before, after) => before.entries != after.entries,
      listener: (context, vault) =>
          context.read<HealthCubit>().audit(vault.entries),
      child: Scaffold(
        appBar: AppBar(title: const Text('PASSWORD HEALTH')),
        body: BlocBuilder<HealthCubit, HealthState>(
          builder: (context, state) {
            final report = state.report;
            if (report == null) {
              return const Center(child: CircularProgressIndicator());
            }
            return ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Text(
                    report.checked == 0
                        ? 'There are no passwords to check yet.'
                        : report.isClean
                        ? 'Checked ${report.checked} passwords. No problems '
                              'found.'
                        : 'Checked ${report.checked} passwords on this '
                              'phone. Nothing leaves the device.',
                    key: const Key('health-summary'),
                    style: TextStyle(
                      color: report.isClean && report.checked > 0
                          ? LeopardColors.ok
                          : LeopardColors.textMuted,
                    ),
                  ),
                ),
                _Section(
                  title: 'Weak',
                  count: report.weak.length,
                  children: [
                    for (final finding in report.weak)
                      _FindingTile(
                        itemId: finding.itemId,
                        title: finding.title,
                        detail: _weakDetail(finding.strength),
                      ),
                  ],
                ),
                _Section(
                  title: 'Reused',
                  count: report.reused.length,
                  children: [
                    for (final finding in report.reused)
                      for (final (index, itemId) in finding.itemIds.indexed)
                        _FindingTile(
                          itemId: itemId,
                          title: finding.titles[index],
                          detail:
                              'Same password as '
                              '${finding.itemIds.length - 1} other '
                              'item${finding.itemIds.length == 2 ? '' : 's'}',
                        ),
                  ],
                ),
                _Section(
                  title: 'Old',
                  count: report.old.length,
                  children: [
                    for (final finding in report.old)
                      _FindingTile(
                        itemId: finding.itemId,
                        title: finding.title,
                        detail:
                            'Not changed for ${finding.age.inDays ~/ 30} '
                            'months',
                      ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  static String _weakDetail(PasswordStrength strength) {
    if (strength.patterns.contains(PasswordPattern.common)) {
      return 'Commonly used password';
    }
    if (strength.patterns.contains(PasswordPattern.sequence)) {
      return 'Predictable sequence · about ${strength.bits.round()} bits';
    }
    if (strength.patterns.contains(PasswordPattern.repeated)) {
      return 'Repeated characters · about ${strength.bits.round()} bits';
    }
    return 'Easy to guess · about ${strength.bits.round()} bits';
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.count,
    required this.children,
  });

  final String title;
  final int count;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SectionLabel('$title · $count'),
      if (children.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text('None', style: TextStyle(color: LeopardColors.textMuted)),
        )
      else
        ...children,
    ],
  );
}

class _FindingTile extends StatelessWidget {
  const _FindingTile({
    required this.itemId,
    required this.title,
    required this.detail,
  });

  final String itemId;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) => ListTile(
    dense: true,
    leading: const Icon(
      Icons.warning_amber_outlined,
      color: LeopardColors.warning,
    ),
    title: Text(title.isEmpty ? '(untitled)' : title),
    subtitle: Text(
      detail,
      style: const TextStyle(color: LeopardColors.textMuted),
    ),
    trailing: const Icon(Icons.chevron_right),
    onTap: () => context.push('/vault/item/$itemId'),
  );
}
