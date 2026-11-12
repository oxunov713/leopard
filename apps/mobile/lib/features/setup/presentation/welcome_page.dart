import 'package:flutter/material.dart';
import 'package:leopard_ui/leopard_ui.dart';

import '../../../core/widgets/page_scaffold.dart';

/// First screen on a phone without a vault: create a new vault, or move an
/// existing one here with the recovery key.
class WelcomePage extends StatelessWidget {
  const WelcomePage({
    super.key,
    required this.onCreate,
    required this.onRestore,
  });

  final VoidCallback onCreate;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: PageBody(
      children: [
        const SizedBox(height: 56),
        const BrandHeader(subtitle: 'Your vault. Your keys.'),
        const SizedBox(height: 48),
        FilledButton(
          key: const Key('welcome-create'),
          onPressed: onCreate,
          child: const Text('Create new vault'),
        ),
        const SizedBox(height: 8),
        const Text(
          'First time: this phone creates the vault and holds its keys.',
          textAlign: TextAlign.center,
          style: TextStyle(color: LeopardColors.textMuted, fontSize: 12),
        ),
        const SizedBox(height: 28),
        OutlinedButton(
          key: const Key('welcome-restore'),
          onPressed: onRestore,
          child: const Text('Restore with recovery key'),
        ),
        const SizedBox(height: 8),
        const Text(
          'Lost or replaced your phone: use the recovery key you wrote down '
          'at setup.',
          textAlign: TextAlign.center,
          style: TextStyle(color: LeopardColors.textMuted, fontSize: 12),
        ),
      ],
    ),
  );
}
