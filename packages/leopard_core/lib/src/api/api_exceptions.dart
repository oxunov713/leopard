import 'api_models.dart';

/// Base class of every error produced by `LeopardApiClient` from an HTTP
/// response. Transport failures (`http.ClientException`, `TimeoutException`,
/// socket errors) are not wrapped and propagate unchanged.
///
/// Subclasses are a closed set keyed on the HTTP status. [code] is the
/// server's machine-readable `error.code` (see `docs/api.md`).
sealed class ApiException implements Exception {
  const ApiException({
    required this.statusCode,
    required this.code,
    required this.message,
    this.requestId,
  });

  /// HTTP status of the response.
  final int statusCode;

  /// `error.code` from the body, or `unknown` if the body had none.
  final String code;

  /// `error.message` from the body. For display and logs only.
  final String message;

  /// The `X-Request-Id` response header, to quote when reading server logs.
  final String? requestId;

  @override
  String toString() => '$runtimeType($statusCode $code): $message';
}

/// 400: `invalid_request`, `invalid_json`.
final class BadRequestException extends ApiException {
  const BadRequestException({
    required super.statusCode,
    required super.code,
    required super.message,
    super.requestId,
  });
}

/// 401: `unauthenticated`, `invalid_token`, `session_revoked`,
/// `session_expired`, `device_auth_failed`, `invalid_credentials`.
final class UnauthorizedException extends ApiException {
  const UnauthorizedException({
    required super.statusCode,
    required super.code,
    required super.message,
    super.requestId,
  });

  /// Whether the session is gone. The client has already dropped its token;
  /// the app MUST now lock and erase VK, the item key and decrypted items
  /// (crypto-spec §11).
  bool get sessionEnded =>
      code == 'session_revoked' ||
      code == 'session_expired' ||
      code == 'invalid_token' ||
      code == 'unauthenticated';
}

/// 403: `mobile_only`, `origin_not_allowed`, `setup_token_required`,
/// `bad_signature`.
final class ForbiddenException extends ApiException {
  const ForbiddenException({
    required super.statusCode,
    required super.code,
    required super.message,
    super.requestId,
  });
}

/// 404: `not_found`, `not_initialised`, `qr_not_found`, `item_not_found`,
/// `session_not_found`.
final class NotFoundException extends ApiException {
  const NotFoundException({
    required super.statusCode,
    required super.code,
    required super.message,
    super.requestId,
  });
}

/// 409: `version_conflict`, `already_initialised`, `qr_not_pending`.
final class ConflictException extends ApiException {
  const ConflictException({
    required super.statusCode,
    required super.code,
    required super.message,
    super.requestId,
    this.current,
  });

  /// For `version_conflict`: the item as the server has it now. Re-fetch,
  /// merge, re-encrypt for `current.version + 1` and retry with
  /// `expectedVersion: current.version`.
  final ItemMeta? current;

  /// The server's current version of the item, if this is a version
  /// conflict.
  int? get serverVersion => current?.version;
}

/// 410: `item_deleted` (the id is a tombstone and is never reused),
/// `qr_expired`.
final class GoneException extends ApiException {
  const GoneException({
    required super.statusCode,
    required super.code,
    required super.message,
    super.requestId,
    this.current,
  });

  /// For `item_deleted`: the tombstone.
  final ItemMeta? current;
}

/// 413 `body_too_large`.
final class PayloadTooLargeException extends ApiException {
  const PayloadTooLargeException({
    required super.statusCode,
    required super.code,
    required super.message,
    super.requestId,
  });
}

/// 429 `rate_limited`.
final class RateLimitedException extends ApiException {
  const RateLimitedException({
    required super.statusCode,
    required super.code,
    required super.message,
    super.requestId,
    this.retryAfter,
  });

  /// The `Retry-After` header, if the server sent a usable one. Do not retry
  /// sooner.
  final Duration? retryAfter;
}

/// 5xx: `internal`, or a gateway error in front of the API.
final class ServerException extends ApiException {
  const ServerException({
    required super.statusCode,
    required super.code,
    required super.message,
    super.requestId,
  });
}

/// Any other non-success status (for example 415 or an unexpected 3xx).
final class UnexpectedStatusException extends ApiException {
  const UnexpectedStatusException({
    required super.statusCode,
    required super.code,
    required super.message,
    super.requestId,
  });
}

/// A success status whose body is not what `docs/api.md` promises: not JSON,
/// a missing or mistyped field, or a binary field of the wrong size. Treat
/// it as a hostile or broken server; nothing from the response was used.
final class MalformedResponseException extends ApiException {
  const MalformedResponseException({
    required super.statusCode,
    required super.message,
    super.requestId,
  }) : super(code: 'malformed_response');
}
