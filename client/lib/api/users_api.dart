import 'dart:convert';
import 'dart:typed_data';

import 'api_client.dart';

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
