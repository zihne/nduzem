import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:opaqueshare/crypto/jwt.dart';

/// Build a JWT with a controlled payload. The signature segment doesn't
/// have to be valid — the client-side helper is decode-only (the server
/// already verified the signature when it issued the token).
String _jwt(Map<String, dynamic> claims) {
  String seg(Map<String, dynamic> m) {
    final b = utf8.encode(jsonEncode(m));
    return base64Url.encode(b).replaceAll('=', '');
  }

  return '${seg({'alg': 'HS256', 'typ': 'JWT'})}.${seg(claims)}.stub-sig';
}

void main() {
  test('decodeJwtPayload returns the middle segment as a map', () {
    final token = _jwt({'sub': 'user-abc', 'exp': 12345});
    final payload = decodeJwtPayload(token);
    expect(payload['sub'], 'user-abc');
    expect(payload['exp'], 12345);
  });

  test('extractSubject pulls the sub claim', () {
    final token = _jwt({'sub': 'user-abc'});
    expect(extractSubject(token), 'user-abc');
  });

  test('extractSubject throws when sub is missing', () {
    final token = _jwt({'exp': 12345});
    expect(() => extractSubject(token), throwsA(isA<JwtDecodeError>()));
  });

  test('decodeJwtPayload throws on malformed input', () {
    expect(
      () => decodeJwtPayload('not.a.jwt.at.all'),
      throwsA(isA<JwtDecodeError>()),
    );
  });

  test('handles a base64url payload without trailing padding', () {
    final token = _jwt({'sub': 'x'});
    expect(extractSubject(token), 'x');
  });
}
