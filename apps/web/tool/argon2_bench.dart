// Temporary: how long does Argon2id take once compiled with dart2js?
import 'dart:typed_data';

import 'package:leopard_core/leopard_core.dart';

Future<void> main() async {
  final crypto = LeopardCrypto();
  for (var i = 0; i < 2; i++) {
    final watch = Stopwatch()..start();
    final kek = await crypto.deriveKek(
      password: LeopardCrypto.passwordBytes('correct horse battery staple'),
      salt: Uint8List.fromList(List.generate(16, (i) => 0x10 + i)),
    );
    // ignore: avoid_print
    print('argon2id dart2js run $i: ${watch.elapsedMilliseconds} ms '
        '${hexEncode(kek).substring(0, 8)}');
  }
}
