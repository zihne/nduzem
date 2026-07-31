import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:opaqueshare/api/auth_api.dart';
import 'package:opaqueshare/api/users_api.dart';
import 'package:opaqueshare/crypto/keys.dart';
import 'package:opaqueshare/features/auth/auth_repository.dart';
import 'package:opaqueshare/storage/secure_storage.dart';

class _FakeApi extends Mock implements AuthApi {}

class _FakeUsersApi extends Mock implements UsersApi {}

class _FakeStore extends Mock implements SecureStore {}

class _FakeKeys extends Mock implements KeypairGenerator {}

void main() {
  late _FakeApi api;
  late _FakeUsersApi usersApi;
  late _FakeStore store;
  late _FakeKeys keys;
  late AuthRepository repo;

  final identityPub = Uint8List.fromList(List.filled(32, 1));
  final signingPub = Uint8List.fromList(List.filled(32, 2));
  final identityPriv = Uint8List.fromList(List.filled(32, 11));
  final signingPriv = Uint8List.fromList(List.filled(32, 22));

  setUp(() {
    api = _FakeApi();
    usersApi = _FakeUsersApi();
    store = _FakeStore();
    keys = _FakeKeys();
    repo = AuthRepository(
      api: api,
      usersApi: usersApi,
      storage: store,
      keys: keys,
    );

    registerFallbackValue(Uint8List(0));

    when(() => store.write(any(), any())).thenAnswer((_) async {});
    when(() => store.writeBytes(any(), any())).thenAnswer((_) async {});
    when(() => store.delete(any())).thenAnswer((_) async {});
    when(() => store.purgeSession()).thenAnswer((_) async {});
    when(() => store.purgeAll()).thenAnswer((_) async {});
    when(() => store.migrateLegacyKeypairIfNeeded()).thenAnswer((_) async {});
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
      expect(session.email, 'a@b.c');
      expect(session.fingerprint.length, 25); // canonical form
      expect(session.mfaEnabled, isFalse); // fresh account

      // ADR-0011: keypair slots are scoped to the newly-issued userId so
      // two accounts on the same device don't collide.
      verify(
        () => store.writeBytes(
          SecureStore.identityPrivateKeyFor('u1'),
          identityPriv,
        ),
      ).called(1);
      verify(
        () => store.writeBytes(
          SecureStore.signingPrivateKeyFor('u1'),
          signingPriv,
        ),
      ).called(1);
      verify(() => store.write(SecureStore.kUserId, 'u1')).called(1);
      verify(() => store.write(SecureStore.kAccessToken, 'A')).called(1);
      verify(() => store.write(SecureStore.kRefreshToken, 'R')).called(1);
      verify(() => store.write(SecureStore.kEmail, 'a@b.c')).called(1);
      verify(() => store.write(SecureStore.kMfaEnabled, 'false')).called(1);
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

      // The M2.x wiring reads the email back from storage inside
      // _acceptTokens to build the session. Ensure the read returns the
      // value we just wrote.
      when(() => store.read(SecureStore.kEmail))
          .thenAnswer((_) async => 'x@y');

      final outcome = await repo.login(email: 'x@y', password: 'p');

      expect(outcome, isA<LoginOutcomeTokens>());
      final tokens = outcome as LoginOutcomeTokens;
      expect(tokens.session.userId, 'user-42');
      expect(tokens.session.email, 'x@y');
      expect(tokens.emailVerified, isTrue);
      // Server issued tokens directly with no TOTP challenge — MFA off.
      expect(tokens.session.mfaEnabled, isFalse);
      verify(() => store.write(SecureStore.kAccessToken, access)).called(1);
      verify(() => store.write(SecureStore.kRefreshToken, 'RR')).called(1);
      verify(() => store.write(SecureStore.kUserId, 'user-42')).called(1);
      verify(() => store.write(SecureStore.kMfaEnabled, 'false')).called(1);
      verify(() => store.write(SecureStore.kEmail, 'x@y')).called(1);
    });

    test('loginTotp success persists mfaEnabled=true', () async {
      final access = jwtFor('user-9');
      when(
        () => api.loginTotp(
          mfaSession: any(named: 'mfaSession'),
          code: any(named: 'code'),
          isRecovery: any(named: 'isRecovery'),
        ),
      ).thenAnswer(
        (_) async => LoginResult.tokens(
          access: access,
          refresh: 'R',
          emailVerified: true,
        ),
      );

      final outcome = await repo.loginTotp(
        mfaSession: 'SESS',
        code: '123456',
        isRecovery: false,
      );

      expect(outcome, isA<LoginOutcomeTokens>());
      expect((outcome as LoginOutcomeTokens).session.mfaEnabled, isTrue);
      verify(() => store.write(SecureStore.kMfaEnabled, 'true')).called(1);
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
      verifyNever(() => store.purgeSession());
      verifyNever(() => store.purgeAll());
    });
  });

  group('setMfaEnabled', () {
    test('persists the flag verbatim', () async {
      await repo.setMfaEnabled(true);
      verify(() => store.write(SecureStore.kMfaEnabled, 'true')).called(1);
      await repo.setMfaEnabled(false);
      verify(() => store.write(SecureStore.kMfaEnabled, 'false')).called(1);
    });
  });

  group('restoreSession', () {
    test('reads mfaEnabled = true when stored', () async {
      when(() => store.read(SecureStore.kUserId))
          .thenAnswer((_) async => 'u-1');
      when(() => store.read(SecureStore.kAccessToken))
          .thenAnswer((_) async => 'A');
      when(() => store.read(SecureStore.kRefreshToken))
          .thenAnswer((_) async => 'R');
      when(() => store.read(SecureStore.kFingerprint))
          .thenAnswer((_) async => '0000000000000000000000000');
      when(() => store.read(SecureStore.kMfaEnabled))
          .thenAnswer((_) async => 'true');

      final session = await repo.restoreSession();
      expect(session?.mfaEnabled, isTrue);
    });

    test('defaults mfaEnabled to false for legacy sessions (key missing)',
        () async {
      when(() => store.read(SecureStore.kUserId))
          .thenAnswer((_) async => 'u-1');
      when(() => store.read(SecureStore.kAccessToken))
          .thenAnswer((_) async => 'A');
      when(() => store.read(SecureStore.kRefreshToken))
          .thenAnswer((_) async => 'R');
      when(() => store.read(SecureStore.kFingerprint))
          .thenAnswer((_) async => '');
      when(() => store.read(SecureStore.kMfaEnabled))
          .thenAnswer((_) async => null);

      final session = await repo.restoreSession();
      expect(session?.mfaEnabled, isFalse);
    });

    // --- self-heal on Android EncryptedSharedPreferences corruption ---

    test('BAD_DECRYPT at startup → wipes storage and returns null', () async {
      // Simulates the real production error: user's device master key
      // no longer matches the on-disk ciphertext (app resign, backup
      // restore, ghost install). App must recover silently — return
      // null session so the router bounces to /login.
      when(() => store.resetOnCorruption()).thenAnswer((_) async {});
      when(() => store.read(SecureStore.kUserId)).thenThrow(
        PlatformException(
          code: 'Exception encountered, read',
          message:
              'javax.crypto.BadPaddingException: error:1e000065:Cipher '
              'functions:OPENSSL_internal:BAD_DECRYPT',
        ),
      );

      final session = await repo.restoreSession();
      expect(session, isNull);
      verify(() => store.resetOnCorruption()).called(1);
    });

    test('BAD_DECRYPT during migration also triggers self-heal', () async {
      // Migration is the FIRST call inside restoreSession — if the
      // legacy-slot probe hits BAD_DECRYPT, we must still recover.
      when(() => store.resetOnCorruption()).thenAnswer((_) async {});
      when(() => store.migrateLegacyKeypairIfNeeded()).thenThrow(
        PlatformException(
          code: 'Exception encountered, read',
          message: 'BadPaddingException',
        ),
      );

      final session = await repo.restoreSession();
      expect(session, isNull);
      verify(() => store.resetOnCorruption()).called(1);
    });

    test('Tink "Could not decrypt key" at startup → self-heal', () async {
      // The Auto Backup shape, and the one the original predicate
      // missed: restoring shared_prefs from the cloud without the
      // hardware-bound master key makes Tink fail to unwrap the KEYSET
      // rather than a value, so neither BAD_DECRYPT nor
      // BadPaddingException appears anywhere in the exception. The app
      // stayed wedged across restarts because of it.
      //
      // Verbatim from a device, via readAll() inside
      // VerifiedContactsRepo.
      when(() => store.resetOnCorruption()).thenAnswer((_) async {});
      when(() => store.read(SecureStore.kUserId)).thenThrow(
        PlatformException(
          code: 'Exception encountered, readAll',
          message: 'java.lang.SecurityException: Could not decrypt key. '
              'decryption failed',
        ),
      );

      final session = await repo.restoreSession();
      expect(session, isNull);
      verify(() => store.resetOnCorruption()).called(1);
    });

    test('bare SecurityException does NOT trigger a wipe', () async {
      // The widening above must stay surgical: this predicate authorises
      // destroying the user's private keys, so a SecurityException
      // without decrypt-failure wording has to propagate untouched.
      when(() => store.read(SecureStore.kUserId)).thenThrow(
        PlatformException(
          code: 'Exception encountered, read',
          message: 'java.lang.SecurityException: user not authenticated',
        ),
      );

      await expectLater(
        repo.restoreSession(),
        throwsA(isA<PlatformException>()),
      );
      verifyNever(() => store.resetOnCorruption());
    });

    test('non-decrypt PlatformException propagates (no silent wipe)',
        () async {
      // Guardrail: we don't want to silently wipe a healthy session
      // when an unrelated platform error occurs (e.g., a keystore
      // hiccup before device is unlocked for the first time). Only
      // the BAD_DECRYPT / BadPaddingException signature triggers the
      // self-heal.
      when(() => store.read(SecureStore.kUserId)).thenThrow(
        PlatformException(
          code: 'unavailable',
          message: 'Keystore not yet available.',
        ),
      );

      await expectLater(
        repo.restoreSession(),
        throwsA(isA<PlatformException>()),
      );
      verifyNever(() => store.resetOnCorruption());
    });
  });

  group('signOut', () {
    test('clears session state via purgeSession, NOT purgeAll', () async {
      // Load-bearing invariant: sign-out MUST preserve the identity
      // state so a same-account re-login can still decrypt K_files.
      await repo.signOut();
      verify(() => store.purgeSession()).called(1);
      verifyNever(() => store.purgeAll());
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
