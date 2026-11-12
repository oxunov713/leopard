import 'package:leopard_web/core/config/app_config.dart';
import 'package:test/test.dart';

void main() {
  test('an https origin is accepted', () {
    final config = AppConfig.parse('https://api.example.com');
    expect(config.isValid, isTrue);
    expect(config.apiUrl, Uri.parse('https://api.example.com'));
    expect(config.allowInsecureHttp, isFalse);
    expect(config.problem, isNull);
  });

  test('http is accepted for a loopback host only', () {
    for (final url in [
      'http://localhost:8080',
      'http://127.0.0.1:8080',
      'http://[::1]:8080',
    ]) {
      final config = AppConfig.parse(url);
      expect(config.isValid, isTrue, reason: url);
      expect(config.allowInsecureHttp, isTrue, reason: url);
    }
    for (final url in [
      'http://api.example.com',
      'http://192.168.1.10:8080',
      'http://localhost.example.com',
    ]) {
      final config = AppConfig.parse(url);
      expect(config.isValid, isFalse, reason: url);
      expect(config.problem, contains('https'), reason: url);
    }
  });

  test('a missing or malformed address is a configuration problem', () {
    expect(AppConfig.parse('').problem, contains('LEOPARD_API_URL'));
    expect(AppConfig.parse('   ').isValid, isFalse);
    for (final url in [
      'api.example.com',
      'ftp://api.example.com',
      'https://',
      'https://api.example.com/?x=1',
      'https://api.example.com/#frag',
      'https://user:pw@api.example.com',
    ]) {
      expect(AppConfig.parse(url).isValid, isFalse, reason: url);
    }
  });

  test('a build without the define shows the problem, not a crash', () {
    // The tests are compiled without --dart-define=LEOPARD_API_URL.
    final config = AppConfig.fromEnvironment();
    expect(config.isValid, isFalse);
    expect(config.problem, isNotNull);
  });
}
