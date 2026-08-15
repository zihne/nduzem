import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:nduzem/storage/secure_storage.dart';

class _FakeBackend extends Mock implements FlutterSecureStorage {}

void main() {
  late _FakeBackend backend;
  late SecureStore store;

  // Backing map so a read after a write returns the latest value.
  late Map<String, String?> disk;

  setUp(() {
    backend = _FakeBackend();
    disk = <String, String?>{};

    when(
      () => backend.write(
        key: any(named: 'key'),
        value: any(named: 'value'),
        iOptions: any(named: 'iOptions'),
        aOptions: any(named: 'aOptions'),
        lOptions: any(named: 'lOptions'),
        webOptions: any(named: 'webOptions'),
        mOptions: any(named: 'mOptions'),
        wOptions: any(named: 'wOptions'),
      ),
    ).thenAnswer((invocation) async {
      final key = invocation.namedArguments[#key] as String;
      final value = invocation.namedArguments[#value] as String?;
      disk[key] = value;
    });

    when(
      () => backend.read(
        key: any(named: 'key'),
        iOptions: any(named: 'iOptions'),
        aOptions: any(named: 'aOptions'),
        lOptions: any(named: 'lOptions'),
        webOptions: any(named: 'webOptions'),
        mOptions: any(named: 'mOptions'),
        wOptions: any(named: 'wOptions'),
      ),
    ).thenAnswer((invocation) async {
      final key = invocation.namedArguments[#key] as String;
      return disk[key];
    });

    when(
      () => backend.delete(
        key: any(named: 'key'),
        iOptions: any(named: 'iOptions'),
        aOptions: any(named: 'aOptions'),
        lOptions: any(named: 'lOptions'),
        webOptions: any(named: 'webOptions'),
        mOptions: any(named: 'mOptions'),
        wOptions: any(named: 'wOptions'),
      ),
    ).thenAnswer((invocation) async {
      final key = invocation.namedArguments[#key] as String;
      disk.remove(key);
    });

    store = SecureStore(backend: backend);
  });

  group('scoped keypair slot naming', () {
    test('per-user slot names include the userId', () {
      expect(
        SecureStore.identityPrivateKeyFor('u1'),
        'auth.identity_private_b64.u1',
      );
      expect(
        SecureStore.identityPublicKeyFor('u1'),
        'auth.identity_public_b64.u1',
      );
      expect(
        SecureStore.signingPrivateKeyFor('u1'),
        'auth.signing_private_b64.u1',
      );
      expect(
        SecureStore.signingPublicKeyFor('u1'),
        'auth.signing_public_b64.u1',
      );
    });

    test('two users get disjoint slot names', () {
      expect(
        SecureStore.identityPrivateKeyFor('u1'),
        isNot(SecureStore.identityPrivateKeyFor('u2')),
      );
    });
  });

  group('migrateLegacyKeypairIfNeeded', () {
    test('no legacy identity slot → no reads beyond the probe', () async {
      await store.migrateLegacyKeypairIfNeeded();
      // Only the cheap probe should have fired. No writes.
      verifyNever(
        () => backend.write(
          key: any(named: 'key'),
          value: any(named: 'value'),
        ),
      );
    });

    test('legacy quartet + kUserId → copies to scoped slots and deletes legacy',
        () async {
      disk['auth.identity_private_b64'] = 'idpriv';
      disk['auth.identity_public_b64'] = 'idpub';
      disk['auth.signing_private_b64'] = 'signpriv';
      disk['auth.signing_public_b64'] = 'signpub';
      disk[SecureStore.kUserId] = 'u-42';

      await store.migrateLegacyKeypairIfNeeded();

      expect(disk['auth.identity_private_b64.u-42'], 'idpriv');
      expect(disk['auth.identity_public_b64.u-42'], 'idpub');
      expect(disk['auth.signing_private_b64.u-42'], 'signpriv');
      expect(disk['auth.signing_public_b64.u-42'], 'signpub');

      expect(disk.containsKey('auth.identity_private_b64'), isFalse);
      expect(disk.containsKey('auth.identity_public_b64'), isFalse);
      expect(disk.containsKey('auth.signing_private_b64'), isFalse);
      expect(disk.containsKey('auth.signing_public_b64'), isFalse);
    });

    test('idempotent: second run after a successful migration is a no-op',
        () async {
      disk['auth.identity_private_b64'] = 'idpriv';
      disk['auth.identity_public_b64'] = 'idpub';
      disk['auth.signing_private_b64'] = 'signpriv';
      disk['auth.signing_public_b64'] = 'signpub';
      disk[SecureStore.kUserId] = 'u-42';

      await store.migrateLegacyKeypairIfNeeded();
      // Snapshot post-migration state.
      final after = Map<String, String?>.from(disk);

      await store.migrateLegacyKeypairIfNeeded();
      expect(disk, after);
    });

    test('legacy present but kUserId missing → leaves everything in place',
        () async {
      disk['auth.identity_private_b64'] = 'idpriv';
      disk['auth.identity_public_b64'] = 'idpub';
      disk['auth.signing_private_b64'] = 'signpriv';
      disk['auth.signing_public_b64'] = 'signpub';
      // No kUserId.

      await store.migrateLegacyKeypairIfNeeded();

      expect(disk['auth.identity_private_b64'], 'idpriv');
      expect(disk['auth.identity_public_b64'], 'idpub');
      expect(disk['auth.signing_private_b64'], 'signpriv');
      expect(disk['auth.signing_public_b64'], 'signpub');
    });

    test('legacy quartet is partial → leaves everything in place', () async {
      // Missing the identity_public slot — the migration must refuse
      // rather than write scoped slots that can't decrypt anything.
      disk['auth.identity_private_b64'] = 'idpriv';
      disk['auth.signing_private_b64'] = 'signpriv';
      disk['auth.signing_public_b64'] = 'signpub';
      disk[SecureStore.kUserId] = 'u-42';

      await store.migrateLegacyKeypairIfNeeded();

      // No scoped slot got written.
      expect(disk.containsKey('auth.identity_private_b64.u-42'), isFalse);
      // Legacy slots are untouched.
      expect(disk['auth.identity_private_b64'], 'idpriv');
      expect(disk['auth.signing_private_b64'], 'signpriv');
      expect(disk['auth.signing_public_b64'], 'signpub');
    });
  });

  group('purgeSession', () {
    test('deletes tokens and MFA flag, keeps identity + userId', () async {
      disk[SecureStore.kAccessToken] = 'A';
      disk[SecureStore.kRefreshToken] = 'R';
      disk[SecureStore.kMfaEnabled] = 'true';
      disk[SecureStore.kUserId] = 'u-1';
      disk[SecureStore.kFingerprint] = '000';
      disk[SecureStore.identityPrivateKeyFor('u-1')] = 'idpriv';

      await store.purgeSession();

      expect(disk.containsKey(SecureStore.kAccessToken), isFalse);
      expect(disk.containsKey(SecureStore.kRefreshToken), isFalse);
      expect(disk.containsKey(SecureStore.kMfaEnabled), isFalse);
      // Preserved: identity + userId + fingerprint (so a same-account
      // re-login can still decrypt K_files sealed under those keys).
      expect(disk[SecureStore.kUserId], 'u-1');
      expect(disk[SecureStore.kFingerprint], '000');
      expect(disk[SecureStore.identityPrivateKeyFor('u-1')], 'idpriv');
    });
  });

  group('purgeAll', () {
    test(
        'deletes the current user\'s scoped keypair but preserves other users',
        () async {
      disk[SecureStore.kUserId] = 'u-current';
      disk[SecureStore.kAccessToken] = 'A';
      disk[SecureStore.identityPrivateKeyFor('u-current')] = 'idpriv-current';
      disk[SecureStore.identityPublicKeyFor('u-current')] = 'idpub-current';
      disk[SecureStore.signingPrivateKeyFor('u-current')] = 'signpriv-current';
      disk[SecureStore.signingPublicKeyFor('u-current')] = 'signpub-current';
      // Another user's keys on the same device — MUST survive.
      disk[SecureStore.identityPrivateKeyFor('u-other')] = 'idpriv-other';
      disk[SecureStore.signingPrivateKeyFor('u-other')] = 'signpriv-other';

      await store.purgeAll();

      // Current user's keypair + session state gone.
      expect(disk.containsKey(SecureStore.kUserId), isFalse);
      expect(disk.containsKey(SecureStore.kAccessToken), isFalse);
      expect(
        disk.containsKey(SecureStore.identityPrivateKeyFor('u-current')),
        isFalse,
      );
      expect(
        disk.containsKey(SecureStore.signingPrivateKeyFor('u-current')),
        isFalse,
      );
      // Other user's slots untouched.
      expect(
        disk[SecureStore.identityPrivateKeyFor('u-other')],
        'idpriv-other',
      );
      expect(
        disk[SecureStore.signingPrivateKeyFor('u-other')],
        'signpriv-other',
      );
    });

    test('no kUserId → still clears session state; no keypair delete needed',
        () async {
      disk[SecureStore.kAccessToken] = 'A';
      // Some other user's key slot the caller doesn't know about.
      disk[SecureStore.identityPrivateKeyFor('u-other')] = 'idpriv-other';

      await store.purgeAll();

      expect(disk.containsKey(SecureStore.kAccessToken), isFalse);
      // Other-user slot survives — this method only knows the active user.
      expect(
        disk[SecureStore.identityPrivateKeyFor('u-other')],
        'idpriv-other',
      );
    });
  });

  group('forgetUserKeypair', () {
    test('deletes only the specified user\'s slots', () async {
      disk[SecureStore.identityPrivateKeyFor('u-a')] = 'a-idpriv';
      disk[SecureStore.identityPublicKeyFor('u-a')] = 'a-idpub';
      disk[SecureStore.signingPrivateKeyFor('u-a')] = 'a-signpriv';
      disk[SecureStore.signingPublicKeyFor('u-a')] = 'a-signpub';
      disk[SecureStore.identityPrivateKeyFor('u-b')] = 'b-idpriv';

      await store.forgetUserKeypair('u-a');

      expect(
        disk.containsKey(SecureStore.identityPrivateKeyFor('u-a')),
        isFalse,
      );
      expect(
        disk.containsKey(SecureStore.signingPublicKeyFor('u-a')),
        isFalse,
      );
      expect(disk[SecureStore.identityPrivateKeyFor('u-b')], 'b-idpriv');
    });
  });
}
