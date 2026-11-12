import 'package:flutter/material.dart';
import 'package:leopard_ui/leopard_ui.dart';

import '../domain/vault_entry.dart';
import 'vault_cubit.dart';

enum ConflictChoice { keepMine, takeServer }

/// Asks the user how to settle a `409 version_conflict` and applies the
/// answer. Repeats if the server changed again in the meantime.
///
/// Returns the final result of the write: [SaveResult.saved] also when the
/// user took the server's copy.
Future<SaveResult> resolveConflicts(
  BuildContext context,
  VaultCubit cubit,
) async {
  while (true) {
    final conflict = cubit.state.conflict;
    if (conflict == null || !context.mounted) {
      return SaveResult.saved;
    }
    final choice = await showDialog<ConflictChoice>(
      context: context,
      barrierDismissible: false,
      builder: (context) => ConflictDialog(conflict: conflict),
    );
    if (choice == ConflictChoice.keepMine) {
      final result = await cubit.resolveKeepMine();
      if (result != SaveResult.conflict) {
        return result;
      }
    } else {
      await cubit.resolveTakeServer();
      return SaveResult.saved;
    }
  }
}

class ConflictDialog extends StatelessWidget {
  const ConflictDialog({super.key, required this.conflict});

  final PendingConflict conflict;

  @override
  Widget build(BuildContext context) {
    final server = conflict.server;
    final serverLine = server == null
        ? 'The copy on the server cannot be shown on this phone.'
        : 'On the server: "${server.item.title}" '
              '(${itemTypeLabel(server.item.type)}, version '
              '${conflict.serverVersion}).';
    return AlertDialog(
      title: const Text('Changed on another device'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            conflict.isDelete
                ? 'This item was changed somewhere else after you opened '
                      'it, so it was not deleted.'
                : 'This item was changed somewhere else after you opened '
                      'it, so your edit was not saved.',
          ),
          const SizedBox(height: 12),
          Text(
            serverLine,
            style: const TextStyle(color: LeopardColors.textMuted),
          ),
        ],
      ),
      actions: [
        TextButton(
          key: const Key('conflict-take-server'),
          onPressed: () => Navigator.of(context).pop(ConflictChoice.takeServer),
          child: const Text('Take server'),
        ),
        TextButton(
          key: const Key('conflict-keep-mine'),
          onPressed: () => Navigator.of(context).pop(ConflictChoice.keepMine),
          child: Text(conflict.isDelete ? 'Delete anyway' : 'Keep mine'),
        ),
      ],
    );
  }
}
