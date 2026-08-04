import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:opaqueshare/features/verify_contact/verified_contacts_repo.dart';
import 'package:opaqueshare/storage/secure_storage.dart';

class _FakeStore extends Mock implements SecureStore {}

void main() {
  const alice = 'u-alice';
  const bob = 'u-bob';

  late _FakeStore store;
  late VerifiedContactsRepo repo;

  // In-memory backing map so `readAll` + reads see writes.
  late Map<String, String> disk;

  setUp(() {
    store = _FakeStore();
    disk = <String, String>{};

    when(() => store.readAll())
        .thenAnswer((_) async => Map<String, String>.from(disk));
    when(() => store.write(any(), any())).thenAnswer((invocation) async {
      disk[invocation.positionalArguments[0] as String] =
          invocation.positionalArguments[1] as String;
    });
    when(() => store.read(any())).thenAnswer((invocation) async {
      return disk[invocation.positionalArguments[0] as String];
    });
    when(() => store.delete(any())).thenAnswer((invocation) async {
      disk.remove(invocation.positionalArguments[0] as String);
    });

    repo = VerifiedContactsRepo(store, localUserId: alice);
  });

  group('scoped keys', () {
    test(
        'markVerified writes {fp, at} JSON under vc.<localUserId>'
        '.<counterpartyId>', () async {
      final at = DateTime.utc(2026, 7, 1, 12);
      await repo.markVerified(
        userId: bob,
        canonical: '6770347913578480527288176',
        at: at,
      );

      expect(disk['vc.u-alice.u-bob'], isNotNull);
      expect(disk['vc.u-alice.u-bob'], contains('6770347913578480527288176'));
      expect(disk['vc.u-alice.u-bob'], contains(at.toIso8601String()));
      // Not written under the legacy shape.
      expect(disk['vc.u-bob'], isNull);
    });

    test('read returns null when nothing is stored', () async {
      expect(await repo.read(bob), isNull);
    });

    test('read parses back the stored payload', () async {
      disk['vc.u-alice.u-bob'] = '{"fp":"6770347913578480527288176",'
          '"at":"2026-07-01T12:00:00.000Z","fpv":2}';
      final vc = await repo.read(bob);
      expect(vc, isNotNull);
      expect(vc!.canonical, '6770347913578480527288176');
      expect(vc.at.toUtc().year, 2026);
    });

    test('a record from an older fingerprint scheme reads as ABSENT', () async {
      // Deliberately NOT a mismatch. A mismatch raises "this contact's
      // fingerprint has changed" — the key-substitution alarm. Firing
      // that at every previously-verified contact just because the app
      // changed how it derives fingerprints is the fastest way to teach
      // users the alarm is noise. Absent means "verify again", which is
      // both true and safe.
      disk['vc.u-alice.u-bob'] = '{"fp":"0000000583409474571453372",'
          '"at":"2026-07-01T12:00:00.000Z","fpv":1}';
      expect(await repo.read(bob), isNull);
    });

    test('a record predating fingerprint versioning reads as ABSENT', () async {
      // No `fpv` at all — written before the field existed, so scheme 1.
      disk['vc.u-alice.u-bob'] =
          '{"fp":"0000000583409474571453372","at":"2026-07-01T12:00:00.000Z"}';
      expect(await repo.read(bob), isNull);
    });

    test('markVerified stamps the current scheme version', () async {
      await repo.markVerified(
        userId: bob,
        canonical: '6770347913578480527288176',
        at: DateTime.utc(2026, 7, 1, 12),
      );
      expect(disk['vc.u-alice.u-bob'], contains('"fpv":2'));
      // And round-trips through read().
      expect((await repo.read(bob))!.canonical, '6770347913578480527288176');
    });

    test('read tolerates a corrupted payload by returning null', () async {
      disk['vc.u-alice.u-bob'] = 'not-valid-json{';
      expect(await repo.read(bob), isNull);
    });

    test('forget deletes the current-user scoped key', () async {
      disk['vc.u-alice.u-bob'] = '{"fp":"x","at":"2026-07-01T00:00:00.000Z"}';
      await repo.forget(bob);
      expect(disk['vc.u-alice.u-bob'], isNull);
    });
  });

  group('null session', () {
    late VerifiedContactsRepo anon;

    setUp(() {
      anon = VerifiedContactsRepo(store, localUserId: null);
    });

    test('read returns null and does not touch storage', () async {
      expect(await anon.read(bob), isNull);
      verifyNever(() => store.read(any()));
    });

    test('markVerified is a no-op', () async {
      await anon.markVerified(
        userId: bob,
        canonical: 'anything',
        at: DateTime.utc(2026, 7, 1),
      );
      expect(disk, isEmpty);
      verifyNever(() => store.write(any(), any()));
    });

    test('forget is a no-op', () async {
      await anon.forget(bob);
      verifyNever(() => store.delete(any()));
    });
  });

  group('bleed regression (ADR-0012)', () {
    test("Alice's verification of Bob does NOT appear when Charlie signs in",
        () async {
      final aliceRepo = VerifiedContactsRepo(store, localUserId: 'u-alice');
      final charlieRepo = VerifiedContactsRepo(store, localUserId: 'u-charlie');

      await aliceRepo.markVerified(
        userId: bob,
        canonical: 'alice-verified-bob-fp',
        at: DateTime.utc(2026, 7, 1),
      );

      // Charlie sees NO verification for Bob — the fingerprint tick on
      // Charlie's send screen must NOT come from Alice's out-of-band
      // verification.
      expect(await charlieRepo.read(bob), isNull);

      // Alice still sees her own verification.
      expect((await aliceRepo.read(bob))!.canonical, 'alice-verified-bob-fp');
    });
  });

  group('legacy migration', () {
    test(
        'first op rewrites vc.<X> as vc.<localUserId>.<X> and '
        'deletes the legacy key', () async {
      disk['vc.u-bob'] = '{"fp":"legacy-fp","at":"2026-07-01T00:00:00.000Z"}';
      disk['vc.u-charlie'] =
          '{"fp":"another-legacy","at":"2026-07-01T00:00:00.000Z"}';

      // Rescoping still happens — that is about storage layout. But the
      // payload predates fingerprint versioning, so it reads as absent
      // rather than as a changed key.
      expect(await repo.read(bob), isNull);

      // Bob's record migrated to Alice's scope.
      expect(disk['vc.u-alice.u-bob'], contains('legacy-fp'));
      expect(disk['vc.u-bob'], isNull);
      // Charlie's legacy record also migrated (single lookup drains
      // the migration for the whole prefix).
      expect(disk['vc.u-alice.u-charlie'], contains('another-legacy'));
      expect(disk['vc.u-charlie'], isNull);
    });

    test(
        'migration is idempotent — a second op after migration does '
        'nothing further', () async {
      disk['vc.u-bob'] = '{"fp":"legacy","at":"2026-07-01T00:00:00.000Z"}';

      await repo.read(bob);
      final snapshot = Map<String, String>.from(disk);

      await repo.read(bob);
      expect(disk, snapshot);
    });

    test(
        'already-scoped key wins if a stray legacy key exists for the '
        'same counterparty', () async {
      // Alice re-verified Bob on the new build BEFORE migrating; the
      // migration must not clobber the fresh verification.
      // Current-scheme record: this represents a verification the user
      // performed on the new build, so it must survive the migration.
      disk['vc.u-alice.u-bob'] = '{"fp":"fresh-verify",'
          '"at":"2026-07-05T00:00:00.000Z","fpv":2}';
      disk['vc.u-bob'] =
          '{"fp":"stale-legacy","at":"2026-07-01T00:00:00.000Z"}';

      final vc = await repo.read(bob);
      expect(vc!.canonical, 'fresh-verify');
      // Legacy is still cleared to remove the ambiguity.
      expect(disk['vc.u-bob'], isNull);
    });

    test('no session → migration does not run', () async {
      final anon = VerifiedContactsRepo(store, localUserId: null);
      disk['vc.u-bob'] = '{"fp":"legacy","at":"2026-07-01T00:00:00.000Z"}';

      await anon.read(bob);
      // Legacy stays put; without a local user id there's no one to
      // attribute it to.
      expect(disk['vc.u-bob'], contains('legacy'));
    });
  });
}
