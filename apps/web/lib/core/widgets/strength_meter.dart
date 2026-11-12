import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// A coarse reading of an entropy figure.
enum StrengthLevel {
  weak('Weak', LeopardColors.danger),
  fair('Fair', LeopardColors.warning),
  good('Good', LeopardColors.brass),
  strong('Strong', LeopardColors.ok),
  excellent('Excellent', LeopardColors.ok);

  const StrengthLevel(this.label, this.color);

  final String label;
  final Color color;
}

/// Maps entropy in bits to a [StrengthLevel].
///
/// The thresholds are for secrets that an attacker can test offline against
/// a fast hash: under 45 bits is within reach of one GPU, 60 bits of a
/// determined attacker, and from 80 bits up guessing is not the weak point.
StrengthLevel strengthLevelFor(double bits) {
  if (bits < 45) return StrengthLevel.weak;
  if (bits < 60) return StrengthLevel.fair;
  if (bits < 80) return StrengthLevel.good;
  if (bits < 110) return StrengthLevel.strong;
  return StrengthLevel.excellent;
}

/// A bar and a label for the entropy of a generated secret.
class StrengthMeter extends StatelessWidget {
  const StrengthMeter({super.key, required this.bits});

  /// Entropy in bits.
  final double bits;

  /// The bar is full at this many bits.
  static const double fullAt = 128;

  @override
  Widget build(BuildContext context) {
    final level = strengthLevelFor(bits);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            key: const Key('strength-bar'),
            value: (bits / fullAt).clamp(0.0, 1.0),
            minHeight: 6,
            color: level.color,
            backgroundColor: LeopardColors.outline,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Text(
              level.label.toUpperCase(),
              key: const Key('strength-label'),
              style: TextStyle(
                fontSize: 11,
                letterSpacing: 1.4,
                fontWeight: FontWeight.w600,
                color: level.color,
              ),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                '${bits.round()} bits of entropy',
                key: const Key('generator-entropy'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  color: LeopardColors.textMuted,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
