import 'dart:convert';

import '../../storage/secure_storage.dart';

/// Persists which counterparties the local user has verified out-of-band
/// and what their fingerprint was at verification time (M2.5).
///
/// On subsequent look-ups (send flow):
///   - **Match** → proceed silently.
///   - **Mismatch** → block the send, show a "the key changed"
///     warning, offer to re-verify.
///   - **No record** → gentle nudge to verify but allow the send
///     (TOFU: trust on first use).
///
/// **Scoping (ADR-0012).** Keys are `vc.<localUserId>.<counterpartyId>`
/// so two accounts on the same device see distinct verification
/// records. `localUserId` is nullable — null means "no active
/// session"; look-ups return null (no record) and mutations no-op,
/// mirroring [TransferHistoryRepository]. All callers use this repo
/// via the Riverpod provider, which supplies the current session's
/// user id automatically.
///
/// **Legacy migration.** Builds prior to ADR-0012 used
/// `vc.<counterpartyId>` keys scoped only by the counterparty, so any
/// verification bled across every account on the device (safety
/// signal from user A visible to user B — worse than the history
/// bleed since the fingerprint tick claims *this user* verified this
/// contact). First use with a non-null `localUserId` rewrites every
/// legacy key under the current user; the currently-signed-in user
/// inherits the verifications that were accumulated under the
/// single-slot storage model. Idempotent.
class VerifiedContactsRepo {
  VerifiedContactsRepo(this._store, {this.localUserId});
  final SecureStore _store;

  /// Local user id whose verification list this repo scopes to. Null
  /// when there's no active session.
  final String? localUserId;

  static const String _prefix = 'vc.';

  static String _keyFor(String localUserId, String counterpartyId) =>
      '$_prefix$localUserId.$counterpartyId';

  static String _legacyKeyFor(String counterpartyId) =>
      '$_prefix$counterpartyId';

  /// Rewrite pre-ADR-0012 `vc.<X>` keys under the current local user
  /// as `vc.<localUserId>.<X>`. Attributes the legacy verifications
  /// to the signed-in user — under the single-slot storage model
  /// those were their verifications in practice. Runs implicitly on
  /// every op; the readAll probe is cheap on flutter_secure_storage.
  Future<void> _migrateIfNeeded() async {
    final uid = localUserId;
    if (uid == null) return;
    final all = await _store.readAll();
    // Legacy shape: `vc.<counterpartyId>` where counterpartyId is a
    // UUID (no dots). Scoped shape: `vc.<uid>.<counterpartyId>` has
    // an extra `.` after the prefix. Filter on the difference so a
    // second run finds nothing to migrate.
    for (final entry in all.entries) {
      final key = entry.key;
      if (!key.startsWith(_prefix)) continue;
      final tail = key.substring(_prefix.length);
      if (tail.contains('.')) continue; // already scoped
      final scoped = _keyFor(uid, tail);
      // Don't clobber an existing scoped record if the same user
      // already re-verified this counterparty on the new build.
      if (await _store.read(scoped) == null) {
        await _store.write(scoped, entry.value);
      }
      await _store.delete(key);
    }
  }

  /// Record that we verified `userId` at `at` with fingerprint
  /// `canonical`. Overwrites any prior record — the newest verification
  /// wins. No-op when there's no active session.
  Future<void> markVerified({
    required String userId,
    required String canonical,
    required DateTime at,
  }) async {
    final localUid = localUserId;
    if (localUid == null) return;
    await _migrateIfNeeded();
    final payload = jsonEncode({
      'fp': canonical,
      'at': at.toIso8601String(),
    });
    await _store.write(_keyFor(localUid, userId), payload);
  }

  /// Look up an existing verification. Returns null when we've never
  /// verified this counterparty on this device — including when
  /// there's no active session.
  Future<VerifiedContact?> read(String userId) async {
    final localUid = localUserId;
    if (localUid == null) return null;
    await _migrateIfNeeded();
    final raw = await _store.read(_keyFor(localUid, userId));
    if (raw == null) return null;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return VerifiedContact(
        canonical: map['fp'] as String,
        at: DateTime.parse(map['at'] as String),
      );
    } on FormatException {
      // Corrupted / legacy record — treat as absent so the next
      // successful verification writes a clean value.
      return null;
    }
  }

  /// Forget a specific counterparty verification for the current
  /// local user. No-op when there's no active session.
  Future<void> forget(String userId) async {
    final localUid = localUserId;
    if (localUid == null) return;
    await _store.delete(_keyFor(localUid, userId));
    // Also remove any residual legacy key for this counterparty so
    // a future migration doesn't resurrect stale data.
    await _store.delete(_legacyKeyFor(userId));
  }
}

class VerifiedContact {
  const VerifiedContact({required this.canonical, required this.at});
  final String canonical;
  final DateTime at;
}
