// Cache of resolved recipients, so a repeat send costs no lookup.
//
// ADR-0039. Every send used to require `/v1/users/lookup`, including a
// second send to the same colleague: `send_screen` held the resolution in
// screen state, and `VerifiedContactsRepo` stores a fingerprint, not the
// keys. So the directory was queried on the app's primary action, with
// the user waiting, and the lookup rate limits were in practice SEND
// limits.
//
// What is stored is what a lookup returns, keyed by the address the user
// typed: the recipient id, both public keys, and the fingerprint — and
// the fingerprint stored is the one WE COMPUTED from the keys, never the
// server's claim about them. Callers verify at lookup time
// (`send_screen`), and caching the server's number would launder an
// unverified value into a trusted one on the next read.
//
// **This is an address book.** A list of who you send files to, on the
// device. The whitepaper says the server holds no social graph; leaving
// an unbounded one on disk sits badly beside that, so entries expire
// after 30 days — long enough that regular correspondents never trigger a
// lookup, short enough that someone you sent one document to in 2026 is
// not still listed in 2028. It is also cleared on sign-out and on
// erasure, unlike the transfer history that preceded it.
//
// Staleness is not the TTL's job. A recipient can rotate keys at any
// time, and the server rejects a send sealed to a stale key at
// `/initiate` (409 `recipient_key_changed`) before any bytes move.
import 'dart:convert';
import 'dart:typed_data';

import '../../storage/secure_storage.dart';

/// A recipient resolved earlier and still usable.
class CachedRecipient {
  const CachedRecipient({
    required this.userId,
    required this.identityPublic,
    required this.signingPublic,
    required this.fingerprint,
    required this.cachedAt,
  });

  final String userId;
  final Uint8List identityPublic;
  final Uint8List signingPublic;

  /// Locally computed from the two keys — never the server's claim.
  final String fingerprint;

  final DateTime cachedAt;
}

class RecipientCache {
  RecipientCache(this._store, {this.localUserId});

  final SecureStore _store;

  /// Scopes entries to the signed-in user, so two accounts on one device
  /// do not see each other's correspondents. Null when signed out, in
  /// which case the cache is inert rather than global.
  final String? localUserId;

  static const String _prefix = 'rc.';

  /// Entries older than this are ignored and swept. Chosen for privacy,
  /// not correctness — see the file header.
  static const Duration ttl = Duration(days: 30);

  static String _keyFor(String localUserId, String address) =>
      '$_prefix$localUserId.${base64Url.encode(utf8.encode(address))}';

  /// Look up a previously resolved recipient.
  ///
  /// Returns null when absent, expired, or unreadable. Every miss is just
  /// a lookup — the caller's existing path — so there is no failure mode
  /// here worth surfacing.
  Future<CachedRecipient?> read(String address) async {
    final uid = localUserId;
    if (uid == null) return null;
    final raw = await _store.read(_keyFor(uid, _normalise(address)));
    if (raw == null) return null;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final cachedAt = DateTime.parse(map['at'] as String);
      if (DateTime.now().difference(cachedAt) > ttl) {
        await _store.delete(_keyFor(uid, _normalise(address)));
        return null;
      }
      return CachedRecipient(
        userId: map['uid'] as String,
        identityPublic: base64Decode(map['ipub'] as String),
        signingPublic: base64Decode(map['spub'] as String),
        fingerprint: map['fp'] as String,
        cachedAt: cachedAt,
      );
    } on Object {
      // Corrupt or written by an older shape. Drop it: a rewrite on the
      // next successful lookup is cheaper than a migration.
      await _store.delete(_keyFor(uid, _normalise(address)));
      return null;
    }
  }

  /// Record a resolution. [fingerprint] MUST be the locally computed one.
  Future<void> write({
    required String address,
    required String userId,
    required Uint8List identityPublic,
    required Uint8List signingPublic,
    required String fingerprint,
  }) async {
    final uid = localUserId;
    if (uid == null) return;
    final payload = jsonEncode({
      'uid': userId,
      'ipub': base64Encode(identityPublic),
      'spub': base64Encode(signingPublic),
      'fp': fingerprint,
      'at': DateTime.now().toIso8601String(),
    });
    await _store.write(_keyFor(uid, _normalise(address)), payload);
  }

  /// Forget one recipient. Called when the server reports the key
  /// changed, so the retry cannot read the stale entry back.
  Future<void> forget(String address) async {
    final uid = localUserId;
    if (uid == null) return;
    await _store.delete(_keyFor(uid, _normalise(address)));
  }

  /// Drop every entry for this local user.
  ///
  /// Called on sign-out and on erasure. Scoped deliberately: another
  /// account's entries on a shared device are not ours to remove, and
  /// clearing them would be indistinguishable from a bug.
  Future<void> clear() async {
    final uid = localUserId;
    if (uid == null) return;
    final all = await _store.readAll();
    final mine = all.keys.where((k) => k.startsWith('$_prefix$uid.'));
    for (final k in mine) {
      await _store.delete(k);
    }
  }

  /// Addresses are what the user typed. Two people writing
  /// `Alice@Example.com` and `alice@example.com` mean the same recipient
  /// and should share one entry — otherwise the cache misses on a
  /// difference the server does not make either.
  static String _normalise(String address) => address.trim().toLowerCase();
}
