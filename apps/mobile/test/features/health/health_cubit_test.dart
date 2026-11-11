import 'package:leopard_core/leopard_core.dart';
import 'package:leopard_mobile/features/health/presentation/health_cubit.dart';
import 'package:test/test.dart';

import '../../support/fakes.dart';

void main() {
  final now = DateTime.utc(2026, 11, 11, 10);
  const strong = 'vR7#kq!2Lm9@xT4&bN6^';

  test('reports weak, reused and old passwords', () async {
    final cubit = HealthCubit(now: () => now);
    await cubit.audit([
      entry(itemIdA, login('Weak', password: 'password1', updatedAt: now)),
      entry(itemIdB, login('Twin 1', password: strong, updatedAt: now)),
      entry(itemIdC, login('Twin 2', password: strong, updatedAt: now)),
      entry(
        deviceIdA,
        login(
          'Old',
          password: 'zQ8\$wE3!rT6@yU1#iO5%',
          updatedAt: now.subtract(const Duration(days: 400)),
        ),
      ),
      entry(
        '5f0c0d3e-1c0a-4b54-9d39-0f2f8c5b3a11',
        SecureNoteItem(
          title: 'Note',
          body: 'x',
          createdAt: now,
          updatedAt: now,
        ),
      ),
    ]);

    final report = cubit.state.report!;
    expect(cubit.state.status, HealthStatus.done);
    expect(report.checked, 4, reason: 'the note has no password');
    expect(report.weak.map((f) => f.itemId), [itemIdA]);
    expect(report.reused.single.itemIds, unorderedEquals([itemIdB, itemIdC]));
    expect(report.old.map((f) => f.itemId), [deviceIdA]);
    expect(report.isClean, isFalse);
    await cubit.close();
  });

  test('an empty or healthy vault is clean', () async {
    final cubit = HealthCubit(now: () => now);
    await cubit.audit(const []);
    expect(cubit.state.report!.isClean, isTrue);
    expect(cubit.state.report!.checked, 0);

    await cubit.audit([
      entry(itemIdA, login('Good', password: strong, updatedAt: now)),
    ]);
    expect(cubit.state.report!.isClean, isTrue);
    expect(cubit.state.report!.checked, 1);
    await cubit.close();
  });

  test('findings never contain a password', () async {
    final cubit = HealthCubit(now: () => now);
    await cubit.audit([
      entry(itemIdA, login('Weak', password: 'password1', updatedAt: now)),
    ]);
    final finding = cubit.state.report!.weak.single;
    expect(finding.title, 'Weak');
    expect(finding.strength, isA<PasswordStrength>());
    await cubit.close();
  });
}
