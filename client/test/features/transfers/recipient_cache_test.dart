// ADR-0039: the recipient cache.
//
// The properties worth pinning are the ones that would be silently wrong:
// scoping (two accounts on a device must not share correspondents),
// expiry (this is an address book on disk, and it must not be permanent),
// normalisation (a case difference must not cause a miss the server would
// not make), and clearing (sign-out and erasure must actually remove it,
// which is precisely what the transfer history that preceded it failed to
// do).
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nduzem/features/transfers/recipient_cache.dart';
import 'package:nduzem/storage/secure_storage.dart';

/// In-memory SecureStore so these are fast and hermetic. Subclassing
/// rather than mocking: every test here exercises real read/write/delete
/// round-trips, and stubbing each call would test the stubs.
class _MemoryStore implements SecureStore {
  final Map<String, String> data = {};

  @override
  Future<void> write(String key, String value) async => data[key] = value;

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> delete(String key) async => data.remove(key);

  @override
  Future<Map<String, String>> readAll() async => Map.of(data);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not needed here');
}

Uint8List _key(int fill) => Uint8List.fromList(List.filled(32, fill));

void main() {
  late _MemoryStore store;

  setUp(() => store = _MemoryStore());

  RecipientCache cacheFor(String? uid) =>
      RecipientCache(store, localUserId: uid);

  Future<void> put(RecipientCache c, String address) => c.write(
        address: address,
        userId: 'recipient-1',
        identityPublic: _key(1),
        signingPublic: _key(2),
        fingerprint: 'ABCD EFGH',
      );

  test('a written recipient reads back', () async {
    final c = cacheFor('me');
    await put(c, 'alice@example.com');

    final got = await c.read('alice@example.com');
    expect(got, isNotNull);
    expect(got!.userId, 'recipient-1');
    expect(got.identityPublic, _key(1));
    expect(got.fingerprint, 'ABCD EFGH');
  });

  test('addresses are normalised, so case is not a miss', () async {
    // The server does not distinguish these, so neither should the
    // cache — otherwise a user who capitalises differently silently
    // pays for a lookup every send.
    final c = cacheFor('me');
    await put(c, 'Alice@Example.com');

    expect(await c.read('alice@example.com'), isNotNull);
    expect(await c.read('  ALICE@EXAMPLE.COM  '), isNotNull);
  });

  test('entries are scoped per local user', () async {
    // Two accounts on one device must not see each other's
    // correspondents. This is the whole reason the key carries the local
    // user id.
    await put(cacheFor('user-a'), 'alice@example.com');

    expect(await cacheFor('user-b').read('alice@example.com'), isNull);
    expect(await cacheFor('user-a').read('alice@example.com'), isNotNull);
  });

  test('signed out, the cache is inert rather than global', () async {
    final c = cacheFor(null);
    await put(c, 'alice@example.com');

    expect(
      store.data,
      isEmpty,
      reason: 'nothing may be written without a local user to scope it to',
    );
    expect(await c.read('alice@example.com'), isNull);
  });

  test('an entry past its TTL is ignored and swept', () async {
    // Written by hand with an old timestamp: the point is that a stale
    // entry is not merely unused but removed, so an address book does
    // not accumulate people you contacted once.
    final old = DateTime.now().subtract(RecipientCache.ttl * 2);
    final c = cacheFor('me');
    await put(c, 'alice@example.com');
    final storedKey = store.data.keys.single;
    final decoded = jsonDecode(store.data[storedKey]!) as Map<String, dynamic>;
    decoded['at'] = old.toIso8601String();
    store.data[storedKey] = jsonEncode(decoded);

    expect(await c.read('alice@example.com'), isNull);
    expect(
      store.data,
      isEmpty,
      reason: 'an expired entry must be deleted, not just skipped',
    );
  });

  test('a corrupt entry is dropped rather than thrown', () async {
    final c = cacheFor('me');
    await put(c, 'alice@example.com');
    store.data[store.data.keys.single] = 'not json';

    expect(await c.read('alice@example.com'), isNull);
    expect(store.data, isEmpty);
  });

  test('forget removes one recipient', () async {
    final c = cacheFor('me');
    await put(c, 'alice@example.com');
    await put(c, 'bob@example.com');

    await c.forget('alice@example.com');

    expect(await c.read('alice@example.com'), isNull);
    expect(await c.read('bob@example.com'), isNotNull);
  });

  test('clear removes only this user\'s entries', () async {
    // Sign-out and erasure call this. Clearing another account's entries
    // would be indistinguishable from a bug, and would lose data that was
    // never ours.
    await put(cacheFor('user-a'), 'alice@example.com');
    await put(cacheFor('user-b'), 'carol@example.com');

    await cacheFor('user-a').clear();

    expect(await cacheFor('user-a').read('alice@example.com'), isNull);
    expect(
      await cacheFor('user-b').read('carol@example.com'),
      isNotNull,
      reason: "another account's correspondents are not ours to delete",
    );
  });
}
