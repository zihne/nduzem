import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:opaqueshare/api/api_client.dart';
import 'package:opaqueshare/api/users_api.dart';

class _FakeClient extends Mock implements ApiClient {}

void main() {
  setUpAll(() => registerFallbackValue(<String, dynamic>{}));

  late _FakeClient client;
  late UsersApi api;

  setUp(() {
    client = _FakeClient();
    api = UsersApi(client);
  });

  test('lookup(email) issues an authed GET with URL-encoded email', () async {
    when(() => client.get(any(), authed: any(named: 'authed'))).thenAnswer(
      (_) async => <String, dynamic>{
        'user_id': 'u-42',
        'identity_pub': base64Encode(List<int>.filled(32, 1)),
        'signing_pub': base64Encode(List<int>.filled(32, 2)),
        'key_fingerprint': '00000 00583 40947 45714 53372',
      },
    );

    final result = await api.lookup(email: 'alice+work@example.com');

    final captured = verify(
      () => client.get(captureAny(), authed: any(named: 'authed')),
    ).captured.single as String;
    expect(captured, startsWith('/v1/users/lookup?email='));
    expect(captured, contains('alice%2Bwork%40example.com'));
    expect(result.userId, 'u-42');
    expect(result.identityPublic.length, 32);
    expect(result.signingPublic.length, 32);
    expect(result.serverKeyFingerprint, '00000 00583 40947 45714 53372');
  });

  test('lookup(handle) uses the handle query parameter', () async {
    when(() => client.get(any(), authed: any(named: 'authed'))).thenAnswer(
      (_) async => <String, dynamic>{
        'user_id': 'u-1',
        'identity_pub': base64Encode(List<int>.filled(32, 0)),
        'signing_pub': base64Encode(List<int>.filled(32, 0)),
        'key_fingerprint': 'X',
      },
    );

    await api.lookup(handle: 'alice');
    final captured = verify(
      () => client.get(captureAny(), authed: any(named: 'authed')),
    ).captured.single as String;
    expect(captured, '/v1/users/lookup?handle=alice');
  });
}
