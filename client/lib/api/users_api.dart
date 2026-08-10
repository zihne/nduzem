import 'dart:convert';
import 'dart:typed_data';

import 'api_client.dart';

/// The exact phrase the erasure endpoint checks, verbatim.
///
/// Mirrors `_ERASURE_CONFIRM_PHRASE` in the server's `users.py`. It is a
/// deliberate speed bump, not a secret: the server uses it to tell "the
/// user typed this on purpose" apart from "some code posted a stray
/// body." Exported so the UI can display exactly what it will send —
/// asking someone to type a phrase we then alter would be a trap.
const String erasureConfirmPhrase = 'ERASE MY ACCOUNT';

/// `/v1/users/*` client.
class UsersApi {
  const UsersApi(this._client);
  final ApiClient _client;

  /// `GET /v1/users/me` — the caller's own account details, decrypted at
  /// the boundary. Client calls this once after every register/login so
  /// the home screen can render `Signed in as alice@example.com (@alice)`
  /// even on fresh-device sign-ins where only the email was typed in.
  ///
  /// Also serves erased accounts (before their access token expires) —
  /// `erasedAt` is populated in that case; the client should route to a
  /// tombstone view rather than the home screen.
  Future<UserMe> me() async {
    final body = await _client.get('/v1/users/me', authed: true);
    return UserMe(
      userId: body['id'] as String,
      email: body['email'] as String? ?? '',
      handle: body['handle'] as String?,
      emailVerified: body['email_verified'] as bool? ?? false,
      mfaEnabled: body['mfa_enabled'] as bool? ?? false,
      isAdmin: body['is_admin'] as bool? ?? false,
      createdAt: DateTime.parse(body['created_at'] as String),
      erasedAt: body['erased_at'] == null
          ? null
          : DateTime.parse(body['erased_at'] as String),
    );
  }

  /// `POST /v1/users/me/identity-key` — publish a NEW identity + signing
  /// keypair (server ADR-0017).
  ///
  /// Only the PUBLIC halves travel. The caller generates the pair
  /// locally and persists the private halves itself; this method has no
  /// way to recover anything and does not pretend to.
  ///
  /// `password`, and `mfaCode` when the account has MFA enabled, are
  /// re-authentication — not encryption inputs. Rotation redirects every
  /// FUTURE transfer to the new key, which is precisely what an attacker
  /// holding a stolen session would want, so the server refuses on a
  /// token alone.
  ///
  /// `mfaIsRecoveryCode` matters more than it looks: the ordinary reason
  /// to rotate is a lost device, which takes the TOTP authenticator with
  /// it. Without this path the second factor would block the recovery it
  /// exists to protect.
  Future<IdentityKeyRotation> rotateIdentityKey({
    required String password,
    required String identityPublicB64,
    required String signingPublicB64,
    String? mfaCode,
    bool mfaIsRecoveryCode = false,
  }) async {
    final body = await _client.post(
      '/v1/users/me/identity-key',
      body: <String, dynamic>{
        'password': password,
        'identity_pub': identityPublicB64,
        'signing_pub': signingPublicB64,
        // The server refuses without this. Sent as a constant rather
        // than a parameter because the UI shows the consequence before
        // it ever calls here — making it optional would let a future
        // caller skip the warning and keep the acknowledgement.
        'acknowledge_pending_unreadable': true,
        if (mfaCode != null) 'mfa_code': mfaCode,
        if (mfaCode != null) 'mfa_is_recovery_code': mfaIsRecoveryCode,
      },
      authed: true,
    );
    return IdentityKeyRotation(
      keyFingerprint: body['key_fingerprint'] as String,
      previousKeyFingerprint: body['previous_key_fingerprint'] as String,
      rotatedAt: DateTime.parse(body['rotated_at'] as String),
      pendingTransfersUnreadable:
          (body['pending_transfers_unreadable'] as num?)?.toInt() ?? 0,
    );
  }

  /// `PUT /v1/users/me/key-backup` — store the encrypted keypair backup.
  ///
  /// `blobB64` is ciphertext produced locally under a recovery key that
  /// never leaves the device. The server holds bytes it cannot open;
  /// this method's only job is not to become curious about them.
  ///
  /// `password` is re-authentication, not an encryption input. A write
  /// REPLACES whatever is stored, so a stolen session alone must not be
  /// able to destroy someone's only route back from device loss — they
  /// would gain nothing readable, and the user would not find out until
  /// they needed it.
  Future<KeyBackupStatus> putKeyBackup({
    required String blobB64,
    required String password,
  }) async {
    final body = await _client.put(
      '/v1/users/me/key-backup',
      body: <String, dynamic>{'blob': blobB64, 'password': password},
      authed: true,
    );
    return KeyBackupStatus.fromJson(body);
  }

  /// `GET /v1/users/me/key-backup` — fetch the blob to unwrap locally.
  ///
  /// Returns null when no backup exists (the server answers 404), which
  /// is an ordinary state rather than an error: most accounts will not
  /// have one until they are prompted.
  Future<String?> getKeyBackupBlob() async {
    try {
      final body = await _client.get('/v1/users/me/key-backup', authed: true);
      return body['blob'] as String;
    } on ApiException catch (exc) {
      if (exc.statusCode == 404) return null;
      rethrow;
    }
  }

  /// `GET /v1/users/me/key-backup/status` — does one exist?
  ///
  /// Separate from the fetch so the app can decide whether to prompt
  /// without pulling the user's encrypted key down on every load.
  Future<KeyBackupStatus> keyBackupStatus() async {
    final body =
        await _client.get('/v1/users/me/key-backup/status', authed: true);
    return KeyBackupStatus.fromJson(body);
  }

  /// `DELETE /v1/users/me/key-backup`. Password-gated for the same
  /// reason as the write: it is destructive.
  Future<KeyBackupStatus> deleteKeyBackup({required String password}) async {
    final body = await _client.delete(
      '/v1/users/me/key-backup',
      body: <String, dynamic>{'password': password},
      authed: true,
    );
    return KeyBackupStatus.fromJson(body);
  }

  /// `POST /v1/users/me/erasure` — GDPR Article 17. Irreversible.
  ///
  /// The confirmation phrase is fixed by the server and checked
  /// verbatim, so it is sent from a constant here rather than composed
  /// at the call site: a typo in a string literal on the client would
  /// surface as a 400 the user cannot act on.
  ///
  /// Failure modes worth distinguishing at the UI layer, all raised as
  /// `ApiException` with the server's own detail text:
  ///   400 — phrase mismatch
  ///   401 — wrong password
  ///   403 — account under moderation review (erasure withheld while an
  ///         abuse investigation is open; server ADR-0025)
  ///   409 — already erased
  Future<ErasureReceipt> eraseAccount({required String password}) async {
    final body = await _client.post(
      '/v1/users/me/erasure',
      body: <String, dynamic>{
        'password': password,
        'confirm': erasureConfirmPhrase,
      },
      authed: true,
    );
    return ErasureReceipt.fromJson(body);
  }

  /// Look up a user by email OR handle (exactly one of the two).
  ///
  /// POST-with-body (not GET-with-query) so the email / handle value
  /// never rides in a URL — that keeps it out of the server's access
  /// log, and out of any reverse-proxy / cloud request log downstream.
  /// See server ADR-0022 amendment 2026-07-02.
  ///
  /// Returns the raw public-key bytes so the caller can compute the
  /// fingerprint locally rather than trusting the server's echo. That's
  /// the whole point of OOB verification — we never take the server's
  /// word for a key/fingerprint binding.
  Future<UserLookup> lookup({String? email, String? handle}) async {
    assert(
      (email == null) != (handle == null),
      'Provide exactly one of email or handle.',
    );
    final payload = <String, dynamic>{
      if (email != null) 'email': email,
      if (handle != null) 'handle': handle,
    };
    final body = await _client.post(
      '/v1/users/lookup',
      body: payload,
      authed: true,
    );
    return UserLookup(
      userId: body['user_id'] as String,
      identityPublic: Uint8List.fromList(
        base64Decode(body['identity_pub'] as String),
      ),
      signingPublic: Uint8List.fromList(
        base64Decode(body['signing_pub'] as String),
      ),
      serverKeyFingerprint: body['key_fingerprint'] as String,
    );
  }
}

/// Response of `GET /v1/users/me`. Fields the caller "owns" — either
/// typed at register/login or a status bit about the caller's own
/// account. See ADR-0032 for why we return this shape (not a JWT-baked
/// payload, not a per-field endpoint).
class UserMe {
  const UserMe({
    required this.userId,
    required this.email,
    required this.handle,
    required this.emailVerified,
    required this.mfaEnabled,
    required this.isAdmin,
    required this.createdAt,
    required this.erasedAt,
  });
  final String userId;
  final String email; // empty string for erased accounts
  final String? handle;
  final bool emailVerified;
  final bool mfaEnabled;
  final bool isAdmin;
  final DateTime createdAt;
  final DateTime? erasedAt;
}

class UserLookup {
  const UserLookup({
    required this.userId,
    required this.identityPublic,
    required this.signingPublic,
    required this.serverKeyFingerprint,
  });
  final String userId;
  final Uint8List identityPublic;
  final Uint8List signingPublic;

  /// What the server claims the fingerprint is. Callers MUST recompute
  /// locally from [identityPublic] + [signingPublic] and compare; a
  /// mismatch signals server misbehaviour (bug, tampering, or algorithm
  /// drift) and MUST NOT be silently accepted.
  final String serverKeyFingerprint;
}


/// Outcome of a successful identity-key rotation.
class IdentityKeyRotation {
  const IdentityKeyRotation({
    required this.keyFingerprint,
    required this.previousKeyFingerprint,
    required this.rotatedAt,
    required this.pendingTransfersUnreadable,
  });

  /// The NEW fingerprint, as the server computed it. Worth showing back
  /// to the user: it is what their contacts will see, and the value the
  /// notification email quotes.
  final String keyFingerprint;
  final String previousKeyFingerprint;
  final DateTime rotatedAt;

  /// Transfers that were waiting and are now permanently undecryptable.
  /// Usually zero-cost — the caller is rotating because the old key is
  /// already gone — but reported honestly rather than hidden.
  final int pendingTransfersUnreadable;
}


/// The receipt returned by a successful erasure.
///
/// Kept as a value rather than discarded because the user is entitled
/// to know what was destroyed and what survives — `retainedNotice`
/// carries the server's statement of what is held back for audit and
/// referential integrity, and it is the only place the user will ever
/// see it. Showing "your account is gone" without it would overstate
/// what happened.
class ErasureReceipt {
  const ErasureReceipt({
    required this.erasedAt,
    required this.pendingTransfersBurned,
    required this.retainedNotice,
  });

  final DateTime erasedAt;

  /// Transfers that were in flight to this account and were destroyed
  /// unread. Worth surfacing: it is the one consequence a user might
  /// not have anticipated when they tapped delete.
  final int pendingTransfersBurned;

  /// What the server keeps, and why. Server ADR-0025.
  final String retainedNotice;

  factory ErasureReceipt.fromJson(Map<String, dynamic> body) => ErasureReceipt(
        erasedAt: DateTime.parse(body['erased_at'] as String),
        pendingTransfersBurned: body['pending_transfers_burned'] as int? ?? 0,
        retainedNotice: body['retained_notice'] as String? ?? '',
      );
}

/// Whether the account has an encrypted key backup, and when it was
/// last written. Deliberately carries no fragment of the blob.
class KeyBackupStatus {
  const KeyBackupStatus({required this.exists, this.updatedAt});

  final bool exists;
  final DateTime? updatedAt;

  factory KeyBackupStatus.fromJson(Map<String, dynamic> body) =>
      KeyBackupStatus(
        exists: body['exists'] as bool? ?? false,
        updatedAt: body['updated_at'] == null
            ? null
            : DateTime.parse(body['updated_at'] as String),
      );
}
