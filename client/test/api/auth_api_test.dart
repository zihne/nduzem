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

  group('/v1/auth/password-reset', () {
    test('requestPasswordReset posts {email}', () async {
      when(
        () => client.post(any(), body: any(named: 'body'), authed: any(named: 'authed')),
      ).thenAnswer((_) async => <String, dynamic>{'sent': true});

      await api.requestPasswordReset(email: 'alice@example.com');

      final captured = verify(
        () => client.post(
          '/v1/auth/password-reset/request',
          body: captureAny(named: 'body'),
        ),
      ).captured.single as Map<String, dynamic>;
      expect(captured, {'email': 'alice@example.com'});
    });

    test('confirmPasswordReset posts {user_id, token, new_password}',
        () async {
      when(
        () => client.post(any(), body: any(named: 'body'), authed: any(named: 'authed')),
      ).thenAnswer((_) async => <String, dynamic>{'ok': true});

      await api.confirmPasswordReset(
        userId: 'u-42',
        token: 'reset-token-value',
        newPassword: 'brand-new-pw',
      );

      final captured = verify(
        () => client.post(
          '/v1/auth/password-reset/confirm',
          body: captureAny(named: 'body'),
        ),
      ).captured.single as Map<String, dynamic>;
      expect(captured, {
        'user_id': 'u-42',
        'token': 'reset-token-value',
        'new_password': 'brand-new-pw',
      });
      // Belt-and-braces: the client MUST NOT accidentally include
      // the current password (there is no "current password" here —
      // the reset link is the auth).
      expect(captured.containsKey('password'), isFalse);
    });
  });
}
