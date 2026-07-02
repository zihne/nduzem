import 'dart:convert';
import 'dart:typed_data';

import 'api_client.dart';

/// `/v1/users/*` client. Currently only the lookup endpoint used by the
/// verify-contact flow; will grow as M2 adds the send loop.
class UsersApi {
  const UsersApi(this._client);
  final ApiClient _client;

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
