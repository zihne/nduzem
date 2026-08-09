// Backup and restore at the repository layer (ADR-0017).
//
// The crypto is tested in test/crypto/recovery_key_test.dart. This file
// is about the wiring around it, where the failures are less obvious:
// what gets uploaded, what gets persisted, and what the code refuses to
// do.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:opaqueshare/api/auth_api.dart';
import 'package:opaqueshare/api/users_api.dart';
import 'package:opaqueshare/crypto/fingerprint.dart';
import 'package:opaqueshare/crypto/keys.dart';
import 'package:opaqueshare/crypto/recovery_key.dart';
import 'package:opaqueshare/features/auth/auth_repository.dart';
import 'package:opaqueshare/storage/secure_storage.dart';
import 'package:sodium_libs/sodium_libs.dart';

import '../../crypto/sodium_test_support.dart';

class _FakeApi extends Mock implements AuthApi {}

class _FakeUsersApi extends Mock implements UsersApi {}

class _FakeStore extends Mock implements SecureStore {}

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();

  final maybeSodium = await tryInitSodium();
  final skipReason = sodiumSkipReason(maybeSodium);
  late final Sodium sodium;
  late final KeypairGenerator keys;
  if (maybeSodium != null) {
    sodium = maybeSodium;
    keys = KeypairGenerator(maybeSodium);
  }

  const userId = 'user-1';

  group(
    'key backup',
    () {
      late _FakeApi api;
      late _FakeUsersApi usersApi;
      late _FakeStore store;
      late AuthRepository repo;
      late IdentityKeypair pair;
      late Map<String, Uint8List> written;
      late String? uploadedBlob;

      setUp(() {
        api = _FakeApi();
        usersApi = _FakeUsersApi();
        store = _FakeStore();
        repo = AuthRepository(
          api: api,
          usersApi: usersApi,
          storage: store,
          keys: keys,
        );
        pair = keys.generate();
        written = {};
        uploadedBlob = null;

        registerFallbackValue(Uint8List(0));
        when(() => store.read(SecureStore.kUserId))
            .thenAnswer((_) async => userId);
        when(() => store.read(any())).thenAnswer((_) async => null);
        when(() => store.read(SecureStore.kUserId))
            .thenAnswer((_) async => userId);
        when(() => store.write(any(), any())).thenAnswer((_) async {});
        when(() => store.writeBytes(any(), any())).thenAnswer((inv) async {
          written[inv.positionalArguments[0] as String] =
              inv.positionalArguments[1] as Uint8List;
        });
        // Default: this device holds the keypair.
        when(() => store.readBytes(SecureStore.identityPrivateKeyFor(userId)))
            .thenAnswer((_) async => pair.identityPrivate);
        when(() => store.readBytes(SecureStore.identityPublicKeyFor(userId)))
            .thenAnswer((_) async => pair.identityPublic);
        when(() => store.readBytes(SecureStore.signingPrivateKeyFor(userId)))
            .thenAnswer((_) async => pair.signingPrivate);
        when(() => store.readBytes(SecureStore.signingPublicKeyFor(userId)))
            .thenAnswer((_) async => pair.signingPublic);

        when(
          () => usersApi.putKeyBackup(
            blobB64: any(named: 'blobB64'),
            password: any(named: 'password'),
          ),
        ).thenAnswer((inv) async {
          uploadedBlob = inv.namedArguments[#blobB64] as String;
          return const KeyBackupStatus(exists: true);
        });
      });

      test('what is uploaded contains no key material', () async {
        // The server stores this. If a private key were recoverable from
        // it without the recovery key, the design is void — so assert it
        // at the boundary where the bytes actually leave, not only in
        // the crypto unit test.
        await repo.createKeyBackup(password: 'pw');
        expect(uploadedBlob, isNotNull);
        final raw = Uint8List.fromList(base64Decode(uploadedBlob!));
        expect(_contains(raw, pair.identityPrivate), isFalse);
        expect(_contains(raw, pair.signingPrivate), isFalse);
      });

      test('the recovery key is returned and never persisted or sent',
          () async {
        // It exists once, in the caller's hands. Writing it to storage
        // would put it next to the thing it protects; sending it would
        // hand the server the key to a blob it holds.
        final recovery = await repo.createKeyBackup(password: 'pw');
        expect(recovery.bytes.length, RecoveryKey.lengthBytes);

        final encoded = recovery.display.replaceAll('-', '');
        for (final value in written.values) {
          expect(_contains(value, recovery.bytes), isFalse);
        }
        verifyNever(() => store.write(any(), encoded));
        expect(uploadedBlob!.contains(encoded), isFalse);
      });

      test('backing up refuses when this device has no keys', () async {
        // Otherwise it would upload a backup of nothing and the user
        // would believe they were protected.
        when(() => store.readBytes(any())).thenAnswer((_) async => null);
        await expectLater(
          repo.createKeyBackup(password: 'pw'),
          throwsA(isA<StateError>()),
        );
        verifyNever(
          () => usersApi.putKeyBackup(
            blobB64: any(named: 'blobB64'),
            password: any(named: 'password'),
          ),
        );
      });

      // --- restore -------------------------------------------------

      test('restoring persists all four key halves', () async {
        final recovery = await repo.createKeyBackup(password: 'pw');
        written.clear();
        when(() => usersApi.getKeyBackupBlob())
            .thenAnswer((_) async => uploadedBlob);
        _stubDirectory(usersApi, pair);

        final restored = await repo.restoreFromKeyBackup(recovery);
        expect(restored.pair.identityPrivate, pair.identityPrivate);
        for (final slot in [
          SecureStore.identityPrivateKeyFor(userId),
          SecureStore.identityPublicKeyFor(userId),
          SecureStore.signingPrivateKeyFor(userId),
          SecureStore.signingPublicKeyFor(userId),
        ]) {
          expect(written.containsKey(slot), isTrue, reason: 'missing $slot');
        }
      });

      test('a wrong recovery key restores nothing', () async {
        await repo.createKeyBackup(password: 'pw');
        written.clear();
        when(() => usersApi.getKeyBackupBlob())
            .thenAnswer((_) async => uploadedBlob);
        _stubDirectory(usersApi, pair);

        await expectLater(
          repo.restoreFromKeyBackup(RecoveryKey.generate(sodium)),
          throwsA(isA<RecoveryKeyMismatch>()),
        );
        expect(written, isEmpty, reason: 'wrote keys despite failing to open');
      });

      test('a backup for a superseded key is refused before writing',
          () async {
        // The rotation case. The blob unwraps perfectly and yields a
        // keypair the directory no longer advertises — installing it
        // would look like success and decrypt nothing. Catching it needs
        // a comparison against what senders will actually seal to.
        final recovery = await repo.createKeyBackup(password: 'pw');
        written.clear();
        when(() => usersApi.getKeyBackupBlob())
            .thenAnswer((_) async => uploadedBlob);
        // The account has since rotated to a different keypair.
        _stubDirectory(usersApi, keys.generate());

        await expectLater(
          repo.restoreFromKeyBackup(recovery),
          throwsA(isA<StaleKeyBackup>()),
        );
        expect(written, isEmpty);
      });

      test('an unreachable directory does not block recovery', () async {
        // Someone restoring is often doing so because things are
        // broken. The unwrap is authenticated on its own, so a lookup
        // failure must not be the thing that stops them.
        final recovery = await repo.createKeyBackup(password: 'pw');
        when(() => usersApi.getKeyBackupBlob())
            .thenAnswer((_) async => uploadedBlob);
        when(() => usersApi.me()).thenThrow(Exception('offline'));

        final restored = await repo.restoreFromKeyBackup(recovery);
        expect(restored.pair.identityPrivate, pair.identityPrivate);
      });

      test('restoring with no backup on the account says so', () async {
        when(() => usersApi.getKeyBackupBlob()).thenAnswer((_) async => null);
        await expectLater(
          repo.restoreFromKeyBackup(RecoveryKey.generate(sodium)),
          throwsA(isA<StateError>()),
        );
      });
    },
    skip: skipReason,
  );
}

/// Make `lookup` return the public halves of [pair], as the directory
/// would for an account using it.
void _stubDirectory(_FakeUsersApi usersApi, IdentityKeypair pair) {
  when(() => usersApi.me()).thenAnswer(
    (_) async => UserMe(
      userId: 'user-1',
      email: 'a@example.com',
      handle: 'alice',
      emailVerified: true,
      mfaEnabled: false,
      isAdmin: false,
      createdAt: DateTime.utc(2026),
      erasedAt: null,
    ),
  );
  when(() => usersApi.lookup(handle: any(named: 'handle'))).thenAnswer(
    (_) async => UserLookup(
      userId: 'user-1',
      identityPublic: pair.identityPublic,
      signingPublic: pair.signingPublic,
      serverKeyFingerprint: fingerprintOf(
        identityPublic: pair.identityPublic,
        signingPublic: pair.signingPublic,
      ).canonical,
    ),
  );
}

bool _contains(Uint8List haystack, Uint8List needle) {
  if (needle.isEmpty || needle.length > haystack.length) return false;
  for (var i = 0; i <= haystack.length - needle.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) return true;
  }
  return false;
}
