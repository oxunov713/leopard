import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:leopard_core/leopard_core.dart';

/// An error the app raises itself, with a message that is safe to show.
///
/// Messages never contain secrets, tokens or server internals.
abstract class AppFailure implements Exception {
  const AppFailure(this.message);

  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// The vault is locked: there is no vault key in memory.
final class VaultLockedFailure extends AppFailure {
  const VaultLockedFailure() : super('The session has ended. Sign in again.');
}

/// Input rejected before any network or crypto work.
final class ValidationFailure extends AppFailure {
  const ValidationFailure(super.message);
}

/// The server answered a login step with something that does not match what
/// this browser computed itself (crypto-spec §10.3), or with a payload that
/// does not decrypt. Nothing from the answer was used.
final class ServerMismatchFailure extends AppFailure {
  const ServerMismatchFailure(super.message);
}

/// Turns any error into a short sentence for the user.
String describeError(Object error) => switch (error) {
  AppFailure(:final message) => message,
  RateLimitedException(:final retryAfter) =>
    retryAfter == null
        ? 'Too many attempts. Try again later.'
        : 'Too many attempts. Try again in ${describeWait(retryAfter)}.',
  UnauthorizedException() => 'The session has ended. Sign in again.',
  ForbiddenException(code: 'origin_not_allowed') =>
    'The server does not accept requests from this site '
        '(LEOPARD_WEB_ORIGIN).',
  ForbiddenException() => 'The server refused the request.',
  ConflictException() => 'The item changed on the server.',
  GoneException() => 'This is no longer available on the server.',
  NotFoundException(code: 'not_initialised') =>
    'This server has no vault yet. Set it up from the phone app.',
  NotFoundException() => 'Not found on the server.',
  PayloadTooLargeException() => 'The item is too large.',
  BadRequestException() => 'The server rejected the request.',
  MalformedResponseException() =>
    'The server sent a response this app does not understand.',
  ApiException(:final statusCode) => 'Server error ($statusCode).',
  LeopardCryptoException() => 'A cryptographic check failed.',
  TimeoutException() => 'The server did not answer in time.',
  http.ClientException() => 'Cannot reach the server. Check the connection.',
  _ => 'Something went wrong.',
};

/// "45 s", "3 min": how long a rate limit asks the user to wait.
String describeWait(Duration wait) {
  if (wait.inSeconds < 90) {
    return '${wait.inSeconds < 1 ? 1 : wait.inSeconds} s';
  }
  return '${(wait.inSeconds / 60).ceil()} min';
}
