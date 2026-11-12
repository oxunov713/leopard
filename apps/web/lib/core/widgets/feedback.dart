import 'package:flutter/material.dart';
import 'package:leopard_ui/leopard_ui.dart';

import '../security/secret_clipboard.dart';

void showMessage(BuildContext context, String message) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// Copies [secret] and tells the user when it will be cleared.
Future<void> copySecret(
  BuildContext context,
  SecretClipboard clipboard,
  String secret, {
  String what = 'Copied',
}) async {
  await clipboard.copy(secret);
  if (context.mounted) {
    showMessage(context, '$what. The clipboard is cleared in 30 seconds.');
  }
}

/// An inline error line.
class ErrorText extends StatelessWidget {
  const ErrorText(this.message, {super.key});

  final String message;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Padding(
        padding: EdgeInsets.only(top: 2),
        child: LeopardIcon(
          LeopardIcons.shieldAlert,
          size: 18,
          color: LeopardColors.danger,
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          message,
          style: const TextStyle(color: LeopardColors.danger),
        ),
      ),
    ],
  );
}

Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  bool destructive = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Text(message),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          style: TextButton.styleFrom(foregroundColor: LeopardColors.textSoft),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: destructive
              ? TextButton.styleFrom(foregroundColor: LeopardColors.danger)
              : null,
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}
