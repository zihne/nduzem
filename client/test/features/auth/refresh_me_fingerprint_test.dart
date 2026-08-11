// `refreshMe` must resync the fingerprint, not just the server-owned fields.
//
// The fingerprint is derived from the keypair on THIS device, and two
// flows change that keypair while the session is live:
//
//   - restore from a recovery key, which installs the original keypair on
//     a device that had none;
//   - key rotation, which replaces it with a new one.
//
// Both call `refreshMe` immediately afterwards, and rotation's call site
// even documents the intent ("pull the session's cached fingerprint back
// in line"). But `refreshMe` rebuilt the session from `/me` alone and
// carried the OLD fingerprint through untouched, so:
//
//   - after a restore, the home screen kept reading an empty fingerprint
//     and kept offering "Restore from recovery key" — the key WAS on the
//     device, and only signing out and back in (which re-runs
//     `restoreSession`, which does derive) made it visible;
//   - after a rotation, the home screen kept showing the superseded
//     number, which is the one thing a safety number must never do.
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:opaqueshare/api/auth_api.dart';
import 'package:opaqueshare/api/users_api.dart';
import 'package:opaqueshare/crypto/fingerprint.dart';
import 'package:opaqueshare/crypto/keys.dart';
import 'package:opaqueshare/features/auth/auth_repository.dart';
import 'package:opaqueshare/storage/secure_storage.dart';

import '../../crypto/sodium_test_support.dart';

class _FakeApi extends Mock implements AuthApi {}

class _FakeUsersApi extends Mock implements UsersApi {}

class _FakeStore extends Mock implements SecureStore {}

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();

  final maybeSodium = await tryInitSodium();
  final skipReason = sodiumSkipReason(maybeSodium);
  late final KeypairGenerator keys;
  if (maybeSodium != null) {
    keys = KeypairGenerator(maybeSodium);
  }

  const userId = 'user-1';

  group(
    'refreshMe and the derived fingerprint',
    () {
      late _FakeUsersApi usersApi;
      late _FakeStore store;
      late AuthRepository repo;
      late IdentityKeypair pair;

      setUp(() {
        usersApi = _FakeUsersApi();
        store = _FakeStore();
        repo = AuthRepository(
          api: _FakeApi(),
          usersApi: usersApi,
          storage: store,
          keys: keys,
        );
        pair = keys.generate();

        when(() => store.write(any(), any())).thenAnswer((_) async {});
        when(() => store.delete(any())).thenAnswer((_) async {});
        when(() => store.readBytes(any())).thenAnswer((_) async => null);

        when(() => usersApi.me()).thenAnswer(
          (_) async => UserMe(
            userId: userId,
            email: 'alice@example.com',
            handle: 'alice',
            emailVerified: true,
            mfaEnabled: false,
            isAdmin: false,
            createdAt: DateTime.utc(2026, 1, 1),
            erasedAt: null,
          ),
        );
      });

      AuthSession sessionWith(String fingerprint) => AuthSession(
            userId: userId,
            email: 'alice@example.com',
            handle: 'alice',
            fingerprint: fingerprint,
            mfaEnabled: false,
          );

      void keypairIsOnDevice(IdentityKeypair p) {
        when(() => store.readBytes(SecureStore.identityPublicKeyFor(userId)))
            .thenAnswer((_) async => p.identityPublic);
        when(() => store.readBytes(SecureStore.signingPublicKeyFor(userId)))
            .thenAnswer((_) async => p.signingPublic);
      }

      test('a restored keypair becomes visible without signing out again',
          () async {
        // The reported bug. Session started with no fingerprint (logged in
        // on a fresh device); the restore then put the keypair on disk.
        keypairIsOnDevice(pair);

        final refreshed = await repo.refreshMe(sessionWith(''));

        final expected = fingerprintOf(
          identityPublic: pair.identityPublic,
          signingPublic: pair.signingPublic,
        ).canonical;
        expect(refreshed.fingerprint, expected);
        expect(
          refreshed.fingerprint,
          isNotEmpty,
          reason: 'an empty fingerprint is what makes the home screen keep '
              'offering "Restore from recovery key" after a successful '
              'restore',
        );
      });

      test('a rotated keypair replaces the old number, never keeps it',
          () async {
        final replacement = keys.generate();
        final oldFp = fingerprintOf(
          identityPublic: pair.identityPublic,
          signingPublic: pair.signingPublic,
        ).canonical;
        keypairIsOnDevice(replacement);

        final refreshed = await repo.refreshMe(sessionWith(oldFp));

        expect(refreshed.fingerprint, isNot(oldFp));
        expect(
          refreshed.fingerprint,
          fingerprintOf(
            identityPublic: replacement.identityPublic,
            signingPublic: replacement.signingPublic,
          ).canonical,
        );
      });

      test('no keypair on device still reports empty, not a stale value',
          () async {
        // `readBytes` returns null for every slot here. Carrying a stale
        // fingerprint forward would tell the user they can verify a key
        // this device does not hold.
        final refreshed = await repo.refreshMe(sessionWith('99999999999'));
        expect(refreshed.fingerprint, isEmpty);
      });

      test('server-owned fields still refresh', () async {
        // Guard against "fixing" this by bypassing /me entirely.
        keypairIsOnDevice(pair);
        final refreshed = await repo.refreshMe(
          sessionWith('').copyWith(handle: 'stale'),
        );
        expect(refreshed.email, 'alice@example.com');
        expect(refreshed.handle, 'alice');
        expect(refreshed.emailVerified, isTrue);
      });
    },
    skip: skipReason,
  );
}
