import 'dart:async';

import 'package:flutter/services.dart';

import 'secret_clipboard.dart';

/// [SecretClipboard] on Flutter's clipboard API, which in a browser is
/// `navigator.clipboard.writeText`.
///
/// What a browser allows, and what it does not:
///
/// * A page can write to the clipboard only while its tab has focus. If the
///   tab is in the background when the timer fires, the write is refused;
///   [clearNow] then keeps its "holds a secret" mark and the app calls it
///   again when the tab is shown, when the session locks and on logout.
/// * A page cannot ask whether the clipboard still holds what it put there
///   (reading needs a separate permission, which the app never requests), so
///   the clipboard is overwritten unconditionally: anything copied elsewhere
///   in the meantime is cleared as well.
/// * Clipboard history tools of the operating system (Windows `Win+V`,
///   clipboard managers) keep their own copies, out of reach of any page.
/// * If the tab is closed first, nothing runs and the secret stays.
final class FlutterSecretClipboard implements SecretClipboard {
  FlutterSecretClipboard({this.clearAfter = const Duration(seconds: 30)});

  /// How long a copied secret stays on the clipboard.
  final Duration clearAfter;

  Timer? _timer;
  bool _holdsSecret = false;

  /// Whether a copied secret may still be on the clipboard.
  bool get holdsSecret => _holdsSecret;

  @override
  Future<void> copy(String secret) async {
    _timer?.cancel();
    await Clipboard.setData(ClipboardData(text: secret));
    _holdsSecret = true;
    _timer = Timer(clearAfter, () => unawaited(clearNow()));
  }

  @override
  Future<void> clearNow() async {
    _timer?.cancel();
    _timer = null;
    if (!_holdsSecret) {
      return;
    }
    try {
      await Clipboard.setData(const ClipboardData(text: ''));
      _holdsSecret = false;
    } on Object {
      // The browser refused (tab not focused). Stay marked; the next call
      // tries again.
    }
  }
}
