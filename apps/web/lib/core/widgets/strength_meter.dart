import 'package:flutter/material.dart';
import 'package:leopard_ui/leopard_ui.dart';

import 'ui_parts.dart';

/// A coarse reading of an entropy figure.
enum StrengthLevel {
  weak('Weak', LeopardColors.danger),
  fair('Fair', warningColor),
  good('Good', LeopardColors.primary),
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

/// A bar and "Strong · 104 bits" for the entropy of a secret.
///
/// [keyed] puts the keys the generator tests look for on the parts; a page
/// that can show two meters at once leaves it off for one of them.
class StrengthMeter extends StatelessWidget {
  const StrengthMeter({super.key, required this.bits, this.keyed = true});

  /// Entropy in bits.
  final double bits;
  final bool keyed;

  /// The bar is full at this many bits.
  static const double fullAt = 128;

  @override
  Widget build(BuildContext context) {
    final level = strengthLevelFor(bits);
    final style = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      color: level.color,
    );
    return Row(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              key: keyed ? const Key('strength-bar') : null,
              value: (bits / fullAt).clamp(0.0, 1.0),
              minHeight: 6,
              color: level.color,
              backgroundColor: LeopardColors.divider,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Text(
          level.label,
          key: keyed ? const Key('strength-label') : null,
          style: style,
        ),
        Text(
          ' · ${bits.round()} bits',
          key: keyed ? const Key('generator-entropy') : null,
          maxLines: 1,
          style: style,
        ),
      ],
    );
  }
}
