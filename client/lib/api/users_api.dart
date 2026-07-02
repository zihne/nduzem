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

  /// Look up a user by email OR handle (exactly one of the two).
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
    final params = <String, String>{};
    if (email != null) params['email'] = email;
    if (handle != null) params['handle'] = handle;
    final query = params.entries
        .map(
          (e) =>
              '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
        )
        .join('&');
    final body = await _client.get('/v1/users/lookup?$query', authed: true);
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
