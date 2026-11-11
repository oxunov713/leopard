/// Build-time configuration of the web app.
///
/// The only setting is the API origin, passed to the compiler:
///
/// ```sh
/// flutter build web --dart-define=LEOPARD_API_URL=https://api.example.com
/// ```
///
/// Nothing is read from the page URL, from storage or from the server, so a
/// link cannot point the app at another API.
final class AppConfig {
  const AppConfig._({this.apiUrl, this.allowInsecureHttp = false, this.problem});

  /// The value compiled into this build.
  factory AppConfig.fromEnvironment() =>
      AppConfig.parse(const String.fromEnvironment('LEOPARD_API_URL'));

  /// Validates [raw] the way the app will use it.
  ///
  /// `https` is required. Plain `http` is accepted for a loopback host only
  /// (`localhost`, `127.0.0.1`, `[::1]`), which is what local development
  /// against `go run ./cmd/leopard-api` needs.
  factory AppConfig.parse(String raw) {
    final text = raw.trim();
    if (text.isEmpty) {
      return const AppConfig._(
        problem:
            'This build has no API address. Build it with '
            '--dart-define=LEOPARD_API_URL=https://your-api-host',
      );
    }
    final uri = Uri.tryParse(text);
    if (uri == null ||
        uri.host.isEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.userInfo.isNotEmpty) {
      return const AppConfig._(
        problem: 'LEOPARD_API_URL is not a valid address.',
      );
    }
    final loopback = _loopbackHosts.contains(uri.host);
    if (uri.scheme != 'https' && !(uri.scheme == 'http' && loopback)) {
      return const AppConfig._(
        problem:
            'LEOPARD_API_URL must use https (http is accepted for localhost '
            'only).',
      );
    }
    return AppConfig._(apiUrl: uri, allowInsecureHttp: uri.scheme == 'http');
  }

  static const Set<String> _loopbackHosts = {'localhost', '127.0.0.1', '::1'};

  /// The API origin, or `null` when [problem] is set.
  final Uri? apiUrl;

  /// Whether [apiUrl] is plain http on a loopback host.
  final bool allowInsecureHttp;

  /// Why the build cannot talk to an API, for the error screen.
  final String? problem;

  bool get isValid => apiUrl != null;
}
