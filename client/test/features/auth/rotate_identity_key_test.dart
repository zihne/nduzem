// Client half of identity-key rotation (ADR-0017).
//
// The endpoint exists because losing the private key used to be
// terminal: the account stayed live and could never decrypt again, with
// a published public key nobody held the private half of. Reachable by a
// wiped phone, cleared browser storage, or WebKit deleting all
// script-writable storage after seven days of Safari use without
// interacting with the site.
//
// These tests are about the two ways the client can make that WORSE:
// publishing a key it cannot use, and displaying a fingerprint the rest
// of the world will not see.
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:opaqueshare/api/auth_api.dart';
import 'package:opaqueshare/api/users_api.dart';
import 'package:opaqueshare/crypto/fingerprint.dart';
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
  late List<String> callOrder;

  const userId = 'user-123';
  final newIdentityPub = Uint8List.fromList(List.filled(32, 7));
  final newSigningPub = Uint8List.fromList(List.filled(32, 9));
  final newIdentityPriv = Uint8List.fromList(List.filled(32, 70));
  final newSigningPriv = Uint8List.fromList(List.filled(32, 90));

  final newFp = fingerprintOf(
    identityPublic: newIdentityPub,
    signingPublic: newSigningPub,
  );

  setUp(() {
    api = _FakeApi();
    usersApi = _FakeUsersApi();
    store = _FakeStore();
    keys = _FakeKeys();
    callOrder = [];
    repo = AuthRepository(
      api: api,
      usersApi: usersApi,
      storage: store,
      keys: keys,
    );

    registerFallbackValue(Uint8List(0));

    when(() => keys.generate()).thenReturn(
      IdentityKeypair(
        identityPublic: newIdentityPub,
        identityPrivate: newIdentityPriv,
        signingPublic: newSigningPub,
        signingPrivate: newSigningPriv,
      ),
    );
    when(() => store.read(SecureStore.kUserId)).thenAnswer((_) async => userId);
    when(() => store.read(any())).thenAnswer((_) async => null);
    when(() => store.read(SecureStore.kUserId)).thenAnswer((_) async => userId);
    when(() => store.write(any(), any())).thenAnswer((invocation) async {
      callOrder.add('write:${invocation.positionalArguments[0]}');
    });
    when(() => store.writeBytes(any(), any())).thenAnswer((invocation) async {
      callOrder.add('persist:${invocation.positionalArguments[0]}');
    });

    when(
      () => usersApi.rotateIdentityKey(
        password: any(named: 'password'),
        identityPublicB64: any(named: 'identityPublicB64'),
        signingPublicB64: any(named: 'signingPublicB64'),
        mfaCode: any(named: 'mfaCode'),
        mfaIsRecoveryCode: any(named: 'mfaIsRecoveryCode'),
      ),
    ).thenAnswer((_) async {
      callOrder.add('publish');
      return IdentityKeyRotation(
        keyFingerprint: newFp.display,
        previousKeyFingerprint: '11111 22222 33333 44444 55555',
        rotatedAt: DateTime.utc(2026, 8, 8),
        pendingTransfersUnreadable: 2,
      );
    });
  });

  test('the new private keys are stored BEFORE the key is published', () async {
    // The ordering is the whole design. Publish-then-persist leaves a
    // window where the directory advertises a key this device cannot
    // use: senders seal to it immediately and the user ends up worse off
    // than before rotating — a cruel result for an operation whose only
    // purpose is recovering from key loss.
    //
    // Persist-then-publish inverts the failure into a harmless one:
    // local keys the server has not heard of. Nothing seals to them, and
    // a retry fixes it.
    await repo.rotateIdentityKey(password: 'pw');

    final persistIdx =
        callOrder.indexWhere((c) => c.startsWith('persist:'));
    final publishIdx = callOrder.indexOf('publish');
    expect(persistIdx, isNonNegative, reason: 'keys were never persisted');
    expect(publishIdx, isNonNegative, reason: 'key was never published');
    expect(
      persistIdx,
      lessThan(publishIdx),
      reason: 'published a key before storing the private half',
    );
  });

  test('all four key halves are persisted, scoped to the user', () async {
    await repo.rotateIdentityKey(password: 'pw');
    for (final slot in [
      SecureStore.identityPrivateKeyFor(userId),
      SecureStore.identityPublicKeyFor(userId),
      SecureStore.signingPrivateKeyFor(userId),
      SecureStore.signingPublicKeyFor(userId),
    ]) {
      expect(callOrder, contains('persist:$slot'), reason: 'missing $slot');
    }
  });

  test('the cached fingerprint is updated to the new one', () async {
    await repo.rotateIdentityKey(password: 'pw');
    verify(() => store.write(SecureStore.kFingerprint, newFp.canonical))
        .called(1);
  });

  test('a server fingerprint that disagrees is refused, not displayed',
      () async {
    // The one case where the user must NOT be handed a number to share.
    // A mismatch means the server stored something other than what we
    // sent, or the two derivations have drifted apart — exactly the
    // condition out-of-band verification exists to catch. Showing it
    // would have the user read a value to their contacts that can never
    // match what those contacts look up.
    when(
      () => usersApi.rotateIdentityKey(
        password: any(named: 'password'),
        identityPublicB64: any(named: 'identityPublicB64'),
        signingPublicB64: any(named: 'signingPublicB64'),
        mfaCode: any(named: 'mfaCode'),
        mfaIsRecoveryCode: any(named: 'mfaIsRecoveryCode'),
      ),
    ).thenAnswer(
      (_) async => IdentityKeyRotation(
        keyFingerprint: '99999 99999 99999 99999 99999',
        previousKeyFingerprint: '11111 22222 33333 44444 55555',
        rotatedAt: DateTime.utc(2026, 8, 8),
        pendingTransfersUnreadable: 0,
      ),
    );

    await expectLater(
      repo.rotateIdentityKey(password: 'pw'),
      throwsA(isA<StateError>()),
    );
    // And the bogus value must not have been cached as ours.
    verifyNever(() => store.write(SecureStore.kFingerprint, any()));
  });

  test('the MFA code and recovery flag reach the API unchanged', () async {
    // A dropped recovery flag would send a recovery code to the TOTP
    // verifier, which rejects it — the lost-device path, which is the
    // ORDINARY reason to be rotating, would simply never work.
    await repo.rotateIdentityKey(
      password: 'pw',
      mfaCode: 'ABCD-1234',
      mfaIsRecoveryCode: true,
    );
    verify(
      () => usersApi.rotateIdentityKey(
        password: 'pw',
        identityPublicB64: base64Encode(newIdentityPub),
        signingPublicB64: base64Encode(newSigningPub),
        mfaCode: 'ABCD-1234',
        mfaIsRecoveryCode: true,
      ),
    ).called(1);
  });

  test('rotation without a signed-in user fails before generating keys',
      () async {
    when(() => store.read(SecureStore.kUserId)).thenAnswer((_) async => null);
    await expectLater(
      repo.rotateIdentityKey(password: 'pw'),
      throwsA(isA<StateError>()),
    );
    verifyNever(() => keys.generate());
  });

  test('the pending-transfer count is surfaced, not swallowed', () async {
    // The honest cost of the operation. Hiding it would let someone
    // rotate and quietly lose mail they could have collected first.
    final result = await repo.rotateIdentityKey(password: 'pw');
    expect(result.pendingTransfersUnreadable, 2);
  });
}
