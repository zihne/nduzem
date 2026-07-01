import 'dart:convert';

/// Payload-decode-only JWT helper.
///
/// The server has already validated the signature by the time it returned
/// the token; the client just needs to read claims (specifically `sub` for
/// the user id, since `/v1/auth/login` doesn't echo the user id in its
/// response body). We do NOT verify the signature client-side — that would
/// require the JWT secret, which lives only on the backend.
///
/// If the token is malformed or the payload isn't valid JSON, this throws
/// [JwtDecodeError] rather than returning null so callers must handle it
/// explicitly.
class JwtDecodeError implements Exception {
  const JwtDecodeError(this.message);
  final String message;
  @override
  String toString() => 'JwtDecodeError: $message';
}

/// Decode the middle segment of a JWT (`header.payload.signature`) into a
/// map. Base64url-safe with automatic padding — real-world JWTs frequently
/// omit the `=` padding.
Map<String, dynamic> decodeJwtPayload(String token) {
  final parts = token.split('.');
  if (parts.length != 3) {
    throw const JwtDecodeError('JWT must have three dot-separated segments.');
  }
  final payload = _b64UrlDecode(parts[1]);
  final decoded = jsonDecode(utf8.decode(payload));
  if (decoded is! Map<String, dynamic>) {
    throw const JwtDecodeError('JWT payload is not a JSON object.');
  }
  return decoded;
}

/// Convenience: pull the `sub` claim out of an access token. Throws if
/// the token is malformed or the claim is missing.
String extractSubject(String token) {
  final claims = decodeJwtPayload(token);
  final sub = claims['sub'];
  if (sub is! String || sub.isEmpty) {
    throw const JwtDecodeError('JWT payload has no `sub` claim.');
  }
  return sub;
}

List<int> _b64UrlDecode(String segment) {
  // Add padding — Dart's `base64Url.decode` requires the string length to
  // be a multiple of 4. JWTs strip padding for compactness.
  final padded = segment.padRight((segment.length + 3) & ~3, '=');
  return base64Url.decode(padded);
}
