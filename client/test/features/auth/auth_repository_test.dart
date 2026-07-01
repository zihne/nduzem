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

    // Mocktail requires `any()` register-fallback values for custom types.
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

      // Private keys landed in secure storage.
      verify(
        () => store.writeBytes(SecureStore.kIdentityPrivate, identityPriv),
      ).called(1);
      verify(
        () => store.writeBytes(SecureStore.kSigningPrivate, signingPriv),
      ).called(1);
      // Tokens + user id landed too.
      verify(() => store.write(SecureStore.kUserId, 'u1')).called(1);
      verify(() => store.write(SecureStore.kAccessToken, 'A')).called(1);
      verify(() => store.write(SecureStore.kRefreshToken, 'R')).called(1);
    });
  });

  group('login', () {
    test('tokens result: persists access + refresh', () async {
      when(
        () => api.login(
          email: any(named: 'email'),
          password: any(named: 'password'),
        ),
      ).thenAnswer(
        (_) async => const LoginResult.tokens(
          access: 'AA',
          refresh: 'RR',
          emailVerified: true,
        ),
      );

      final result = await repo.login(email: 'x@y', password: 'p');

      expect(result, isA<LoginTokens>());
      verify(() => store.write(SecureStore.kAccessToken, 'AA')).called(1);
      verify(() => store.write(SecureStore.kRefreshToken, 'RR')).called(1);
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

      final result = await repo.login(email: 'x@y', password: 'p');
      expect(result, isA<LoginMfaRequired>());
      verifyNever(() => store.write(SecureStore.kAccessToken, any()));
      verifyNever(() => store.write(SecureStore.kRefreshToken, any()));
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
