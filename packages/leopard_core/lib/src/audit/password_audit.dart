import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import '../crypto/encoding.dart';
import '../generator/strength.dart';
import '../models/vault_item.dart';

/// A decrypted item together with the server-side id it is stored under.
/// The id is not part of the encrypted payload, so audits need both.
final class AuditInput {
  const AuditInput({required this.id, required this.item});

  /// The item's UUID.
  final String id;

  /// The decrypted item.
  final VaultItem item;
}

/// A password that scored below the threshold or matches a weak pattern.
final class WeakPasswordFinding {
  const WeakPasswordFinding({
    required this.itemId,
    required this.title,
    required this.strength,
  });

  final String itemId;
  final String title;

  /// The estimate that triggered the finding. Never contains the password.
  final PasswordStrength strength;
}

/// A group of items that share one password.
final class ReusedPasswordFinding {
  const ReusedPasswordFinding({required this.itemIds, required this.titles});

  /// Ids of the items sharing the password, in input order (two or more).
  final List<String> itemIds;

  /// Titles of the same items, in the same order.
  final List<String> titles;
}

/// A password that has not been changed for longer than the limit.
final class OldPasswordFinding {
  const OldPasswordFinding({
    required this.itemId,
    required this.title,
    required this.updatedAt,
    required this.age,
  });

  final String itemId;
  final String title;

  /// The item's own `updatedAt` (from inside the encrypted payload).
  final DateTime updatedAt;
  final Duration age;
}

/// The result of [PasswordAuditor.audit].
final class PasswordAuditReport {
  const PasswordAuditReport({
    required this.weak,
    required this.reused,
    required this.old,
    required this.checked,
  });

  final List<WeakPasswordFinding> weak;
  final List<ReusedPasswordFinding> reused;
  final List<OldPasswordFinding> old;

  /// Number of items that had a password to check.
  final int checked;

  /// Whether nothing was found.
  bool get isClean => weak.isEmpty && reused.isEmpty && old.isEmpty;
}

/// Local password health checks over decrypted items.
///
/// Everything runs in memory on the device. Nothing is sent anywhere and
/// nothing should be persisted: findings refer to items by id and title and
/// never contain a password or a hash of one. Run the audit after unlock
/// and drop the report on lock.
///
/// Only items with a password are checked (logins, and Wi-Fi networks that
/// have a passphrase); see `VaultItem.auditablePassword`.
final class PasswordAuditor {
  /// [weakThresholdBits]: passwords estimated below this are weak.
  /// [maxAge]: passwords unchanged for longer than this are old.
  PasswordAuditor({
    Cryptography? cryptography,
    this.weakThresholdBits = 50,
    this.maxAge = const Duration(days: 365),
  }) : _sha256 = (cryptography ?? Cryptography.instance).sha256();

  final Sha256 _sha256;

  /// Entropy estimate below which a password is reported as weak.
  final double weakThresholdBits;

  /// Age beyond which a password is reported as old.
  final Duration maxAge;

  /// Passwords that score below [weakThresholdBits] or that match a common
  /// password or pattern (see `estimatePasswordStrength`).
  List<WeakPasswordFinding> findWeak(Iterable<AuditInput> items) {
    final findings = <WeakPasswordFinding>[];
    for (final input in items) {
      final password = input.item.auditablePassword;
      if (password == null) continue;
      final strength = estimatePasswordStrength(password);
      if (strength.bits < weakThresholdBits ||
          strength.patterns.contains(PasswordPattern.common)) {
        findings.add(
          WeakPasswordFinding(
            itemId: input.id,
            title: input.item.title,
            strength: strength,
          ),
        );
      }
    }
    return findings;
  }

  /// Groups of two or more items with exactly the same password.
  ///
  /// Passwords are compared through their SHA-256 digests, so the grouping
  /// table never holds a second copy of a password. The digests exist only
  /// inside this call; they are not returned and MUST NOT be stored (an
  /// unsalted hash of a password is nearly as sensitive as the password).
  Future<List<ReusedPasswordFinding>> findReused(
    Iterable<AuditInput> items,
  ) async {
    final groups = <String, List<AuditInput>>{};
    for (final input in items) {
      final password = input.item.auditablePassword;
      if (password == null || password.isEmpty) continue;
      final digest = await _sha256.hash(utf8.encode(password));
      groups.putIfAbsent(hexEncode(digest.bytes), () => []).add(input);
    }
    final findings = [
      for (final group in groups.values)
        if (group.length > 1)
          ReusedPasswordFinding(
            itemIds: [for (final input in group) input.id],
            titles: [for (final input in group) input.item.title],
          ),
    ];
    groups.clear();
    return findings;
  }

  /// Passwords whose item was last updated more than [maxAge] before [now].
  ///
  /// This uses the item's `updatedAt`, which changes on any edit of the
  /// item, not only of the password: an item is never reported old sooner
  /// than it should be, but editing its notes resets the clock.
  List<OldPasswordFinding> findOld(
    Iterable<AuditInput> items, {
    required DateTime now,
  }) {
    final findings = <OldPasswordFinding>[];
    for (final input in items) {
      if (input.item.auditablePassword == null) continue;
      final age = now.toUtc().difference(input.item.updatedAt);
      if (age > maxAge) {
        findings.add(
          OldPasswordFinding(
            itemId: input.id,
            title: input.item.title,
            updatedAt: input.item.updatedAt,
            age: age,
          ),
        );
      }
    }
    return findings;
  }

  /// Runs all three checks.
  Future<PasswordAuditReport> audit(
    Iterable<AuditInput> items, {
    required DateTime now,
  }) async {
    final list = items.toList(growable: false);
    return PasswordAuditReport(
      weak: findWeak(list),
      reused: await findReused(list),
      old: findOld(list, now: now),
      checked: list.where((i) => i.item.auditablePassword != null).length,
    );
  }
}
