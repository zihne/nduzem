import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:opaqueshare/api/auth_api.dart';
import 'package:opaqueshare/crypto/keys.dart';
import 'package:opaqueshare/features/auth/auth_repository.dart';
import 'package:opaqueshare/storage/secure_storage.dart';

class _FakeApi extends Mock implements AuthApi {}

class _FakeStore extends Mock implements SecureStore {}

class _FakeKeys extends Mock implements KeypairGenerator {}

void main() {
  late _FakeApi api;
  late _FakeStore store;
  late _FakeKeys keys;
  late AuthRepository repo;

  final identityPub = Uint8List.fromList(List.filled(32, 1));
  final signingPub = Uint8List.fromList(List.filled(32, 2));
  final identityPriv = Uint8List.fromList(List.filled(32, 11));
  final signingPriv = Uint8List.fromList(List.filled(32, 22));

  setUp(() {
    api = _FakeApi();
    store = _FakeStore();
    keys = _FakeKeys();
    repo = AuthRepository(api: api, storage: store, keys: keys);

    registerFallbackValue(Uint8List(0));

    when(() => store.write(any(), any())).thenAnswer((_) async {});
    when(() => store.writeBytes(any(), any())).thenAnswer((_) async {});
    when(() => store.delete(any())).thenAnswer((_) async {});
    when(() => store.purgeAuth()).thenAnswer((_) async {});
    when(() => store.read(any())).thenAnswer((_) async => null);
  });

  IdentityKeypair buildPair() => IdentityKeypair(
        identityPublic: identityPub,
        identityPrivate: identityPriv,
        signingPublic: signingPub,
        signingPrivate: signingPriv,
      );

  // Build a JWT whose payload contains `sub: <userId>`. The client only
  // decodes; the signature doesn't need to be valid.
  String jwtFor(String userId) {
    String seg(Map<String, dynamic> m) =>
        base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
    return '${seg({'alg': 'HS256'})}.${seg({'sub': userId})}.sig';
  }

  group('register', () {
    test('generates keys, POSTs, persists tokens + keypair', () async {
      when(keys.generate).thenReturn(buildPair());
      when(
        () => api.register(
          email: any(named: 'email'),
          password: any(named: 'password'),
          identityPublicB64: any(named: 'identityPublicB64'),
          signingPublicB64: any(named: 'signingPublicB64'),
          handle: any(named: 'handle'),
        ),
      ).thenAnswer(
        (_) async => const RegisterResult(
          userId: 'u1',
          access: 'A',
          refresh: 'R',
          keyFingerprint: '',
        ),
      );

      final session = await repo.register(
        email: 'a@b.c',
        password: 'correct-horse-battery',
      );

      expect(session.userId, 'u1');
      expect(session.fingerprintHex.length, 64); // SHA-256 hex

      verify(() => store.writeBytes(SecureStore.kIdentityPrivate, identityPriv))
          .called(1);
      verify(() => store.writeBytes(SecureStore.kSigningPrivate, signingPriv))
          .called(1);
      verify(() => store.write(SecureStore.kUserId, 'u1')).called(1);
      verify(() => store.write(SecureStore.kAccessToken, 'A')).called(1);
      verify(() => store.write(SecureStore.kRefreshToken, 'R')).called(1);
    });
  });

  group('login', () {
    test(
        'tokens: persists access + refresh + user_id, returns LoginOutcomeTokens',
        () async {
      final access = jwtFor('user-42');
      when(
        () => api.login(
          email: any(named: 'email'),
          password: any(named: 'password'),
        ),
      ).thenAnswer(
        (_) async => LoginResult.tokens(
          access: access,
          refresh: 'RR',
          emailVerified: true,
        ),
      );

      final outcome = await repo.login(email: 'x@y', password: 'p');

      expect(outcome, isA<LoginOutcomeTokens>());
      final tokens = outcome as LoginOutcomeTokens;
      expect(tokens.session.userId, 'user-42');
      expect(tokens.emailVerified, isTrue);
      verify(() => store.write(SecureStore.kAccessToken, access)).called(1);
      verify(() => store.write(SecureStore.kRefreshToken, 'RR')).called(1);
      verify(() => store.write(SecureStore.kUserId, 'user-42')).called(1);
    });

    test('tokens with emailVerified=false: outcome flags it for the caller',
        () async {
      when(
        () => api.login(
          email: any(named: 'email'),
          password: any(named: 'password'),
        ),
      ).thenAnswer(
        (_) async => LoginResult.tokens(
          access: jwtFor('u1'),
          refresh: 'R',
          emailVerified: false,
        ),
      );

      final outcome = await repo.login(email: 'x@y', password: 'p');
      expect(outcome, isA<LoginOutcomeTokens>());
      expect((outcome as LoginOutcomeTokens).emailVerified, isFalse);
    });

    test('mfa required: does NOT persist any token', () async {
      when(
        () => api.login(
          email: any(named: 'email'),
          password: any(named: 'password'),
        ),
      ).thenAnswer(
        (_) async => const LoginResult.mfaRequired(mfaSession: 'MFAS'),
      );

      final outcome = await repo.login(email: 'x@y', password: 'p');
      expect(outcome, isA<LoginOutcomeMfaRequired>());
      expect((outcome as LoginOutcomeMfaRequired).mfaSession, 'MFAS');
      verifyNever(() => store.write(SecureStore.kAccessToken, any()));
      verifyNever(() => store.write(SecureStore.kRefreshToken, any()));
    });
  });

  group('password reset', () {
    test('requestPasswordReset forwards to the API', () async {
      when(() => api.requestPasswordReset(email: any(named: 'email')))
          .thenAnswer((_) async {});
      await repo.requestPasswordReset(email: 'alice@example.com');
      verify(() => api.requestPasswordReset(email: 'alice@example.com'))
          .called(1);
    });

    test('confirmPasswordReset forwards to the API without touching storage',
        () async {
      when(
        () => api.confirmPasswordReset(
          userId: any(named: 'userId'),
          token: any(named: 'token'),
          newPassword: any(named: 'newPassword'),
        ),
      ).thenAnswer((_) async {});
      await repo.confirmPasswordReset(
        userId: 'u-1',
        token: 'T',
        newPassword: 'brand-new-pw',
      );
      verify(
        () => api.confirmPasswordReset(
          userId: 'u-1',
          token: 'T',
          newPassword: 'brand-new-pw',
        ),
      ).called(1);
      // The server already killed every prior refresh token — but the
      // unauth'd confirm flow has no local session to touch.
      verifyNever(() => store.write(SecureStore.kAccessToken, any()));
      verifyNever(() => store.purgeAuth());
    });
  });

  group('signOut', () {
    test('purges secure storage', () async {
      await repo.signOut();
      verify(() => store.purgeAuth()).called(1);
    });
  });

  group('TokenSource', () {
    test('readAccessToken falls back to secure storage when cache empty',
        () async {
      when(() => store.read(SecureStore.kAccessToken))
          .thenAnswer((_) async => 'FROM_STORE');
      expect(await repo.readAccessToken(), 'FROM_STORE');
    });

    test('refreshAccessToken hits /refresh + persists + returns fresh access',
        () async {
      when(() => store.read(SecureStore.kRefreshToken))
          .thenAnswer((_) async => 'OLD_R');
      when(() => api.refresh(refreshToken: any(named: 'refreshToken')))
          .thenAnswer(
        (_) async => const TokenPair(access: 'NEW_A', refresh: 'NEW_R'),
      );

      final fresh = await repo.refreshAccessToken();
      expect(fresh, 'NEW_A');
      verify(() => store.write(SecureStore.kAccessToken, 'NEW_A')).called(1);
      verify(() => store.write(SecureStore.kRefreshToken, 'NEW_R')).called(1);
    });
  });
}
