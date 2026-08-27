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

import 'package:nduzem/api/auth_api.dart';
import 'package:nduzem/api/users_api.dart';
import 'package:nduzem/crypto/fingerprint.dart';
import 'package:nduzem/crypto/keys.dart';
import 'package:nduzem/crypto/recovery_key.dart';
import 'package:nduzem/features/auth/auth_repository.dart';
import 'package:nduzem/storage/secure_storage.dart';
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

      test('backing up a superseded key is refused, and uploads nothing',
          () async {
        // THE BUG THIS FIXES. Validation used to exist only on restore,
        // so a device that missed a rotation performed elsewhere would
        // wrap its dead keypair, upload it, and report success. The user
        // found out at restore — later, on another device, with no
        // alternative left.
        //
        // The directory advertises a different keypair than this device
        // holds, which is exactly the post-rotation state.
        _stubDirectory(usersApi, keys.generate());

        await expectLater(
          repo.createKeyBackup(password: 'pw'),
          throwsA(isA<SupersededKeyBackup>()),
        );
        expect(
          uploadedBlob,
          isNull,
          reason: 'a doomed backup must not reach the server — leaving one '
              'there would overwrite a good backup with a useless one',
        );
      });

      test('the refusal names both keys, so the user can act', () async {
        // Reduced to "backup failed" this is worse than the bug: the user
        // retries, fails again, and learns nothing. They need to know
        // which key this device has and which the account uses, because
        // the fix is to back up from the OTHER device.
        _stubDirectory(usersApi, keys.generate());

        try {
          await repo.createKeyBackup(password: 'pw');
          fail('expected a refusal');
        } on SupersededKeyBackup catch (exc) {
          expect(exc.deviceFingerprint, isNotEmpty);
          expect(exc.publishedFingerprint, isNotEmpty);
          expect(exc.deviceFingerprint, isNot(exc.publishedFingerprint));
          expect(exc.toString(), contains(exc.deviceFingerprint));
          expect(exc.toString(), contains(exc.publishedFingerprint));
        }
      });

      test('backing up the CURRENT key still works', () async {
        // The check must not break the ordinary case: this device holds
        // the keypair the account publishes.
        _stubDirectory(usersApi, pair);

        final recovery = await repo.createKeyBackup(password: 'pw');
        expect(recovery, isNotNull);
        expect(uploadedBlob, isNotNull);
      });

      test('an unreachable directory does not block taking a backup',
          () async {
        // Same tolerance as restore. Someone taking a backup may well be
        // doing so BECAUSE something is already wrong; refusing on a
        // failed lookup would deny them protection at the moment they are
        // trying to obtain it. The worst case is a backup that fails the
        // check later at restore, which is where we started — no worse.
        when(() => usersApi.me()).thenThrow(Exception('offline'));

        final recovery = await repo.createKeyBackup(password: 'pw');
        expect(recovery, isNotNull);
        expect(uploadedBlob, isNotNull);
      });

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
        //
        // The device is emptied first. That is not a concession to the
        // `UnverifiableRestore` check — it is what this test always meant.
        // "Recovery" presupposes having nothing to recover FROM, and the
        // fixture previously left setUp's keypair in place by accident,
        // so it was really asserting that an unverified restore may
        // overwrite a WORKING key. That is the hazard, not the guarantee.
        // Back up while the keys are still here, THEN lose them — which
        // is also the real sequence a user lives through.
        final recovery = await repo.createKeyBackup(password: 'pw');
        when(() => usersApi.getKeyBackupBlob())
            .thenAnswer((_) async => uploadedBlob);
        when(() => usersApi.me()).thenThrow(Exception('offline'));
        for (final slot in [
          SecureStore.identityPrivateKeyFor(userId),
          SecureStore.identityPublicKeyFor(userId),
          SecureStore.signingPrivateKeyFor(userId),
          SecureStore.signingPublicKeyFor(userId),
        ]) {
          when(() => store.readBytes(slot)).thenAnswer((_) async => null);
        }

        final restored = await repo.restoreFromKeyBackup(recovery);
        expect(restored.pair.identityPrivate, pair.identityPrivate);
      });

      test('an unverifiable restore is refused when the device has keys',
          () async {
        // The mirror hazard. `_persistKeypair` overwrites all four slots,
        // and the restore screen is reachable from Settings on a HEALTHY
        // device. Skipping the check there could replace a working key
        // with an unverified one, and the loss surfaces later as
        // "nothing decrypts any more".
        final recovery = await repo.createKeyBackup(password: 'pw');
        written.clear();
        when(() => usersApi.getKeyBackupBlob())
            .thenAnswer((_) async => uploadedBlob);
        when(() => usersApi.me()).thenThrow(Exception('offline'));
        // setUp leaves this device holding `pair`.

        await expectLater(
          repo.restoreFromKeyBackup(recovery),
          throwsA(isA<UnverifiableRestore>()),
        );
        expect(
          written,
          isEmpty,
          reason: 'a working keypair must not be overwritten by a restore '
              'we could not verify',
        );
      });

      test('an unverifiable restore PROCEEDS when the device has nothing',
          () async {
        // The case the tolerance exists for: a wiped device, a directory
        // that cannot be reached, and nothing to lose. Refusing here
        // would block recovery at the one moment it is needed.
        final recovery = await repo.createKeyBackup(password: 'pw');
        when(() => usersApi.getKeyBackupBlob())
            .thenAnswer((_) async => uploadedBlob);
        when(() => usersApi.me()).thenThrow(Exception('offline'));
        // This device holds no keys.
        for (final slot in [
          SecureStore.identityPrivateKeyFor(userId),
          SecureStore.identityPublicKeyFor(userId),
          SecureStore.signingPrivateKeyFor(userId),
          SecureStore.signingPublicKeyFor(userId),
        ]) {
          when(() => store.readBytes(slot)).thenAnswer((_) async => null);
        }

        final restored = await repo.restoreFromKeyBackup(recovery);
        expect(restored.pair.identityPrivate, pair.identityPrivate);
      });

      test('the staleness check works for an account with no handle',
          () async {
        // Handles are OPTIONAL. `_publishedFingerprint` used to bail out
        // when one was absent, which silently disabled this check — and
        // the backup-side check — for every user who never chose a
        // handle. Not a weaker check: none at all, invisibly.
        final recovery = await repo.createKeyBackup(password: 'pw');
        written.clear();
        when(() => usersApi.getKeyBackupBlob())
            .thenAnswer((_) async => uploadedBlob);
        _stubDirectory(usersApi, keys.generate(), handle: null);

        await expectLater(
          repo.restoreFromKeyBackup(recovery),
          throwsA(isA<StaleKeyBackup>()),
          reason: 'the check must fall back to the email address',
        );
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
void _stubDirectory(
  _FakeUsersApi usersApi,
  IdentityKeypair pair, {
  String? handle = 'alice',
}) {
  when(() => usersApi.me()).thenAnswer(
    (_) async => UserMe(
      userId: 'user-1',
      email: 'a@example.com',
      handle: handle,
      emailVerified: true,
      mfaEnabled: false,
      isAdmin: false,
      createdAt: DateTime.utc(2026),
      erasedAt: null,
    ),
  );
  when(
    () => usersApi.lookup(
      handle: any(named: 'handle'),
      email: any(named: 'email'),
    ),
  ).thenAnswer(
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
