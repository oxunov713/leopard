import 'dart:async';

import 'package:flutter/services.dart';

import 'secret_clipboard.dart';

/// [SecretClipboard] for Android.
///
/// Uses the app's own method channel (see `MainActivity.kt`) so the clip can
/// be flagged `EXTRA_IS_SENSITIVE`, which keeps it out of the clipboard
/// preview and keyboard suggestions on Android 13+. Falls back to Flutter's
/// plain clipboard API where the channel is missing (tests).
final class PlatformSecretClipboard implements SecretClipboard {
  PlatformSecretClipboard({this.clearAfter = const Duration(seconds: 30)});

  static const MethodChannel _channel = MethodChannel(
    'uz.azizbek.leopard/clipboard',
  );

  /// How long a copied secret stays on the clipboard.
  final Duration clearAfter;

  Timer? _timer;
  bool _holdsSecret = false;

  @override
  Future<void> copy(String secret) async {
    _timer?.cancel();
    try {
      await _channel.invokeMethod<void>('copySensitive', {'text': secret});
    } on MissingPluginException {
      await Clipboard.setData(ClipboardData(text: secret));
    }
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
    _holdsSecret = false;
    try {
      await _channel.invokeMethod<void>('clear');
    } on MissingPluginException {
      await Clipboard.setData(const ClipboardData(text: ''));
    } on PlatformException {
      // Nothing more can be done; the clip stays until overwritten.
    }
  }
}
