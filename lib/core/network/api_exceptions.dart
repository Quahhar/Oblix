import 'package:dio/dio.dart';

class ApiException implements Exception {
  final String message;
  final int? statusCode;

  ApiException(this.message, {this.statusCode});

  /// Map a raw Dio failure to the matching typed exception, so callers can
  /// react to what went wrong (401 → re-auth, no route → retry later) instead
  /// of string-matching.
  factory ApiException.fromDio(DioException e) {
    final status = e.response?.statusCode;
    final message = _serverDetail(e) ?? e.message ?? 'Request failed';
    if (status == null) return NetworkException(message);
    switch (status) {
      case 401:
        return UnauthorizedException(message);
      case 404:
        return NotFoundException(message);
      case 409:
        return ConflictException(message);
      case 429:
        return RateLimitedException(
          message,
          _retryAfter(e.response?.headers.value('retry-after')),
        );
      default:
        if (status >= 500) return ServerException(message);
        return ApiException(message, statusCode: status);
    }
  }

  static Duration? _retryAfter(String? header) {
    final seconds = int.tryParse(header ?? '');
    return seconds == null ? null : Duration(seconds: seconds);
  }

  /// FastAPI reports errors as {"detail": ...}.
  static String? _serverDetail(DioException e) {
    final data = e.response?.data;
    if (data is Map && data['detail'] is String) {
      return data['detail'] as String;
    }
    return null;
  }

  @override
  String toString() => 'ApiException($statusCode): $message';
}

class UnauthorizedException extends ApiException {
  UnauthorizedException([super.message = 'Unauthorized'])
    : super(statusCode: 401);
}

class NotFoundException extends ApiException {
  NotFoundException([super.message = 'Not found']) : super(statusCode: 404);
}

class ConflictException extends ApiException {
  ConflictException([super.message = 'Conflict']) : super(statusCode: 409);
}

class ServerException extends ApiException {
  ServerException([super.message = 'Server error']) : super(statusCode: 500);
}

class NetworkException extends ApiException {
  NetworkException([super.message = 'Network error']);
}

/// 429 — the auth endpoints rate-limit by IP+email. [retryAfter] comes from
/// the Retry-After header when the server sent one.
class RateLimitedException extends ApiException {
  final Duration? retryAfter;
  RateLimitedException([super.message = 'Too many attempts', this.retryAfter])
    : super(statusCode: 429);
}
