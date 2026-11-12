import 'package:flutter/material.dart';
import 'package:leopard_ui/leopard_ui.dart';

/// The Leopard mark and name shown on the setup and lock screens.
class BrandHeader extends StatelessWidget {
  const BrandHeader({super.key, this.subtitle});

  final String? subtitle;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      const LeopardMark(size: 56),
      const SizedBox(height: 16),
      Text('Leopard', style: Theme.of(context).textTheme.headlineLarge),
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

/// A large page title, as on the main tabs.
class LargeTitle extends StatelessWidget {
  const LargeTitle(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
    child: Text(
      text,
      style: Theme.of(context).textTheme.headlineLarge?.copyWith(fontSize: 34),
    ),
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

/// A rounded surface card.
class Panel extends StatelessWidget {
  const Panel({super.key, required this.child, this.padding});

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: padding ?? const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: LeopardColors.surface,
      borderRadius: BorderRadius.circular(20),
    ),
    child: child,
  );
}

/// Rows grouped in one surface card and separated by dividers.
class CardGroup extends StatelessWidget {
  const CardGroup({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Material(
    color: LeopardColors.surface,
    borderRadius: BorderRadius.circular(20),
    clipBehavior: Clip.antiAlias,
    child: Column(
      children: [
        for (final (index, child) in children.indexed) ...[
          if (index > 0) const Divider(),
          child,
        ],
      ],
    ),
  );
}
