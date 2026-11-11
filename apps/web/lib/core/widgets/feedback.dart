import 'package:flutter/material.dart';

import '../../app/theme.dart';
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
      const Icon(Icons.error_outline, size: 18, color: LeopardColors.danger),
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

/// Small upper-case section heading.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
    child: Text(
      text.toUpperCase(),
      style: const TextStyle(
        fontSize: 11,
        letterSpacing: 1.6,
        fontWeight: FontWeight.w600,
        color: LeopardColors.brass,
      ),
    ),
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
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
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
