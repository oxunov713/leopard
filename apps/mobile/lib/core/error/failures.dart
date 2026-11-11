import 'dart:async';
import 'dart:io';

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
  const VaultLockedFailure() : super('The vault is locked.');
}

/// The server no longer accepts this phone's device key (it was revoked by a
/// recovery on another phone, or the vault was reset).
final class DeviceRevokedFailure extends AppFailure {
  const DeviceRevokedFailure()
    : super(
        'The server did not accept this phone. It may have been replaced '
        'through recovery on another device.',
      );
}

/// Local secure storage could not be read or written.
final class StorageFailure extends AppFailure {
  const StorageFailure([
    super.message = 'Secure storage on this device is unavailable.',
  ]);
}

/// Input rejected before any network or crypto work.
final class ValidationFailure extends AppFailure {
  const ValidationFailure(super.message);
}

/// Turns any error into a short sentence for the user.
String describeError(Object error) => switch (error) {
  AppFailure(:final message) => message,
  RateLimitedException(:final retryAfter) =>
    retryAfter == null
        ? 'Too many attempts. Try again later.'
        : 'Too many attempts. Try again in ${retryAfter.inSeconds} s.',
  UnauthorizedException() => 'The session has ended. Unlock again.',
  ForbiddenException(code: 'setup_token_required') =>
    'This server requires a setup token.',
  ForbiddenException() => 'The server refused the request.',
  ConflictException(code: 'already_initialised') =>
    'This server already has a vault. Use the recovery key to register '
        'a new phone.',
  ConflictException() => 'The item changed on the server.',
  GoneException() => 'This is no longer available on the server.',
  NotFoundException() => 'Not found on the server.',
  PayloadTooLargeException() => 'The item is too large.',
  BadRequestException() => 'The server rejected the request.',
  MalformedResponseException() =>
    'The server sent a response this app does not understand.',
  ApiException(:final statusCode) => 'Server error ($statusCode).',
  LeopardCryptoException() => 'A cryptographic check failed.',
  TimeoutException() => 'The server did not answer in time.',
  SocketException() ||
  HandshakeException() ||
  TlsException() ||
  http.ClientException() => 'Cannot reach the server. Check the connection.',
  _ => 'Something went wrong.',
};
