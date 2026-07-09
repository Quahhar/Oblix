class ApiException implements Exception {
  final String message;
  final int? statusCode;

  ApiException(this.message, {this.statusCode});

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
