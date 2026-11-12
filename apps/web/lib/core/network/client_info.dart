import 'package:flutter/foundation.dart';

/// What this browser says about itself in `client_info` when it asks to log
/// in. The phone shows it next to the request; it is untrusted and for
/// display only. The server adds the real `User-Agent` header itself.
Map<String, Object?> describeThisBrowser() => {
  'browser': 'Leopard web',
  'platform': switch (defaultTargetPlatform) {
    TargetPlatform.android => 'Android',
    TargetPlatform.iOS => 'iOS',
    TargetPlatform.macOS => 'macOS',
    TargetPlatform.windows => 'Windows',
    TargetPlatform.linux => 'Linux',
    TargetPlatform.fuchsia => 'Fuchsia',
  },
};
