import 'dart:convert';

import '../../storage/secure_storage.dart';

/// Persists which counterparties the user has verified out-of-band and
/// what their fingerprint was at verification time (M2.5).
///
/// On subsequent looks-ups (M2 send flow, once it lands):
///   - **Match** → proceed silently.
///   - **Mismatch** → block the send, show a "the key changed"
///     warning, offer to re-verify.
///   - **No record** → gentle nudge to verify but allow the send
///     (TOFU: trust on first use).
///
/// Values are namespaced under `vc:<userId>` so the M9.5 erasure purge
/// can wipe them alongside the auth state.
class VerifiedContactsRepo {
  VerifiedContactsRepo(this._store);
  final SecureStore _store;

  static const String _prefix = 'vc.';

  static String _keyFor(String userId) => '$_prefix$userId';

  /// Record that we verified `userId` at `at` with fingerprint
  /// `canonical`. Overwrites any prior record — the newest verification
  /// wins.
  Future<void> markVerified({
    required String userId,
    required String canonical,
    required DateTime at,
  }) async {
    final payload = jsonEncode({
      'fp': canonical,
      'at': at.toIso8601String(),
    });
    await _store.write(_keyFor(userId), payload);
  }

  /// Look up an existing verification. Returns null when we've never
  /// verified this counterparty on this device.
  Future<VerifiedContact?> read(String userId) async {
    final raw = await _store.read(_keyFor(userId));
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

  Future<void> forget(String userId) => _store.delete(_keyFor(userId));
}

class VerifiedContact {
  const VerifiedContact({required this.canonical, required this.at});
  final String canonical;
  final DateTime at;
}
