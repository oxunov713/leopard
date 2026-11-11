import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leopard_web/core/security/flutter_secret_clipboard.dart';
import 'package:leopard_web/core/security/password_handoff.dart';
import 'package:leopard_web/core/widgets/strength_meter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FlutterSecretClipboard', () {
    late List<String> written;
    late bool refuse;

    setUp(() {
      written = [];
      refuse = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              if (refuse) {
                throw PlatformException(code: 'copy_fail');
              }
              final arguments = call.arguments as Map<Object?, Object?>;
              written.add(arguments['text']! as String);
            }
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    test('a copied secret is overwritten after 30 seconds', () {
      fakeAsync((async) {
        final clipboard = FlutterSecretClipboard()..copy('s3cret');
        async.flushMicrotasks();
        expect(written, ['s3cret']);
        expect(clipboard.holdsSecret, isTrue);

        async.elapse(const Duration(seconds: 29));
        expect(written, ['s3cret']);
        async.elapse(const Duration(seconds: 1));
        expect(written, ['s3cret', '']);
        expect(clipboard.holdsSecret, isFalse);
      });
    });

    test('copying again restarts the 30 seconds', () {
      fakeAsync((async) {
        final clipboard = FlutterSecretClipboard()..copy('one');
        async.elapse(const Duration(seconds: 20));
        clipboard.copy('two');
        async.elapse(const Duration(seconds: 20));
        expect(written, ['one', 'two']);
        async.elapse(const Duration(seconds: 10));
        expect(written, ['one', 'two', '']);
      });
    });

    test('clearNow does nothing unless this app copied a secret', () {
      fakeAsync((async) {
        final clipboard = FlutterSecretClipboard()..clearNow();
        async.flushMicrotasks();
        expect(written, isEmpty);

        clipboard.copy('s3cret');
        async.flushMicrotasks();
        clipboard.clearNow();
        async.flushMicrotasks();
        expect(written, ['s3cret', '']);

        // Already cleared: the timer has nothing left to do.
        async.elapse(const Duration(seconds: 60));
        expect(written, ['s3cret', '']);
      });
    });

    test('a clear the browser refuses is retried on the next call', () {
      fakeAsync((async) {
        final clipboard = FlutterSecretClipboard()..copy('s3cret');
        async.flushMicrotasks();

        // The tab is in the background when the timer fires.
        refuse = true;
        async.elapse(const Duration(seconds: 30));
        expect(written, ['s3cret']);
        expect(clipboard.holdsSecret, isTrue);

        // The tab is shown again.
        refuse = false;
        clipboard.clearNow();
        async.flushMicrotasks();
        expect(written, ['s3cret', '']);
        expect(clipboard.holdsSecret, isFalse);
      });
    });
  });

  test('PasswordHandoff gives a password out once', () {
    final handoff = PasswordHandoff();
    expect(handoff.take(), isNull);
    handoff.offer('generated');
    expect(handoff.take(), 'generated');
    expect(handoff.take(), isNull);
    handoff
      ..offer('again')
      ..clear();
    expect(handoff.take(), isNull);
  });

  test('strength levels', () {
    expect(strengthLevelFor(0), StrengthLevel.weak);
    expect(strengthLevelFor(44.9), StrengthLevel.weak);
    expect(strengthLevelFor(45), StrengthLevel.fair);
    expect(strengthLevelFor(62), StrengthLevel.good);
    expect(strengthLevelFor(80), StrengthLevel.strong);
    expect(strengthLevelFor(128), StrengthLevel.excellent);
  });
}
