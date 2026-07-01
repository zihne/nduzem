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

  group('/v1/auth/mfa/enroll (wire-shape regression)', () {
    test('mfaEnrollBegin reads {secret, otpauth_url}', () async {
      when(
        () => client.post(any(), body: any(named: 'body'), authed: any(named: 'authed')),
      ).thenAnswer(
        (_) async => <String, dynamic>{
          'secret': 'JBSWY3DPEHPK3PXP',
          'otpauth_url': 'otpauth://totp/OpaqueShare:a?secret=…',
        },
      );

      final result = await api.mfaEnrollBegin();

      expect(result.secret, 'JBSWY3DPEHPK3PXP');
      expect(result.otpauthUrl, startsWith('otpauth://'));
    });

    test('mfaEnrollConfirm returns {mfaEnabled, recoveryCodes}', () async {
      when(
        () => client.post(any(), body: any(named: 'body'), authed: any(named: 'authed')),
      ).thenAnswer(
        (_) async => <String, dynamic>{
          'mfa_enabled': true,
          'recovery_codes': ['abc-123', 'def-456'],
        },
      );

      final result = await api.mfaEnrollConfirm(code: '123456');

      expect(result.mfaEnabled, isTrue);
      expect(result.recoveryCodes, ['abc-123', 'def-456']);

      final captured = verify(
        () => client.post(
          '/v1/auth/mfa/enroll/confirm',
          body: captureAny(named: 'body'),
          authed: any(named: 'authed'),
        ),
      ).captured.single as Map<String, dynamic>;
      expect(captured, {'code': '123456'});
    });
  });

  group('/v1/auth/login/totp (wire-shape regression)', () {
    test('loginTotp posts {mfa_session, code, is_recovery_code} — NOT is_recovery',
        () async {
      // Server field is `is_recovery_code` per LoginTotpRequest. If the
      // client sends `is_recovery`, Pydantic silently drops it and every
      // recovery-code login is treated as TOTP → recovery-code login
      // would fail with 401. This test locks the field name.
      when(
        () => client.post(any(), body: any(named: 'body'), authed: any(named: 'authed')),
      ).thenAnswer(
        (_) async => <String, dynamic>{
          'access': 'A',
          'refresh': 'R',
          'email_verified': true,
        },
      );

      await api.loginTotp(
        mfaSession: 'SESS',
        code: '123456',
        isRecovery: true,
      );

      final captured = verify(
        () => client.post(
          '/v1/auth/login/totp',
          body: captureAny(named: 'body'),
        ),
      ).captured.single as Map<String, dynamic>;
      expect(captured, {
        'mfa_session': 'SESS',
        'code': '123456',
        'is_recovery_code': true,
      });
      expect(captured.containsKey('is_recovery'), isFalse);
    });
  });
}
