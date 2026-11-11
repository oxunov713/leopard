import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// The Leopard wordmark shown on the setup and lock screens.
class LeopardMark extends StatelessWidget {
  const LeopardMark({super.key, this.subtitle});

  final String? subtitle;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 64,
        height: 64,
        decoration: BoxDecoration(
          border: Border.all(color: LeopardColors.brass, width: 1.5),
          borderRadius: BorderRadius.circular(6),
        ),
        child: const Icon(
          Icons.lock_outline,
          color: LeopardColors.brass,
          size: 30,
        ),
      ),
      const SizedBox(height: 16),
      const Text(
        'LEOPARD',
        style: TextStyle(
          fontSize: 22,
          letterSpacing: 6,
          fontWeight: FontWeight.w600,
          color: LeopardColors.text,
        ),
      ),
      if (subtitle != null) ...[
        const SizedBox(height: 6),
        Text(
          subtitle!,
          textAlign: TextAlign.center,
          style: const TextStyle(color: LeopardColors.textMuted),
        ),
      ],
    ],
  );
}

/// A scrolling, padded page body that stays readable on wide screens.
class PageBody extends StatelessWidget {
  const PageBody({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          children: children,
        ),
      ),
    ),
  );
}

/// A bordered panel.
class Panel extends StatelessWidget {
  const Panel({super.key, required this.child, this.padding});

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: padding ?? const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: LeopardColors.surface,
      border: Border.all(color: LeopardColors.outline),
      borderRadius: BorderRadius.circular(6),
    ),
    child: child,
  );
}
