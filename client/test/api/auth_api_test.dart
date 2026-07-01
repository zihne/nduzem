import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:opaqueshare/api/api_client.dart';
import 'package:opaqueshare/api/auth_api.dart';

class _FakeClient extends Mock implements ApiClient {}

void main() {
  setUpAll(() => registerFallbackValue(<String, dynamic>{}));

  late _FakeClient client;
  late AuthApi api;

  setUp(() {
    client = _FakeClient();
    api = AuthApi(client);
  });

  group('/v1/auth/verify-email', () {
    test('verifyEmail (link form) posts {user_id, token}', () async {
      when(
        () => client.post(any(), body: any(named: 'body'), authed: any(named: 'authed')),
      ).thenAnswer((_) async => <String, dynamic>{});

      await api.verifyEmail(userId: 'U', token: 'T');

      final captured = verify(
        () => client.post(
          '/v1/auth/verify-email',
          body: captureAny(named: 'body'),
        ),
      ).captured.single as Map<String, dynamic>;
      expect(captured, {'user_id': 'U', 'token': 'T'});
    });

    test('verifyEmailCode (code form) posts {email, code} — NOT {user_id, code}',
        () async {
      // This is the regression this test protects against. The server's
      // VerifyEmailRequest validator rejects mixed shapes with 422.
      when(
        () => client.post(any(), body: any(named: 'body'), authed: any(named: 'authed')),
      ).thenAnswer((_) async => <String, dynamic>{});

      await api.verifyEmailCode(email: 'alice@example.com', code: '123456');

      final captured = verify(
        () => client.post(
          '/v1/auth/verify-email',
          body: captureAny(named: 'body'),
        ),
      ).captured.single as Map<String, dynamic>;
      expect(captured, {'email': 'alice@example.com', 'code': '123456'});
      expect(captured.containsKey('user_id'), isFalse);
    });
  });
}
