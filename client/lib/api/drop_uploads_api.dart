import 'api_client.dart';

/// `/v1/uploads/*` client (ADR-0040 phase 4b) — the **unauthenticated**
/// upload path. Nothing here is authed: the uploader has no account at
/// all, which is the point of the mode.
///
/// A deliberate asymmetry with [DropsApi]: that one is the owner's side
/// and every call is authed. Keeping them in separate classes mirrors
/// the server, where `drop_uploads.py` takes no `CurrentUserDep` so the
/// auth boundary is a property of the file.
///
/// The server answers a **uniform 404** for a missing drop, a wrong
/// password, a revoked, expired or full drop and a blocked owner. So a
/// 404 here means "you cannot upload through this link" and nothing
/// more — do not try to infer a reason, and do not show the user one.
class DropUploadsApi {
  const DropUploadsApi(this._client);
  final ApiClient _client;

  /// `GET /v1/uploads/{id}` — can this link be used, and how big a file
  /// does it take.
  ///
  /// Returns 200 with `open: false` for a closed OR non-existent drop,
  /// so the page can say "no longer accepting files" rather than look
  /// broken. No reason is supplied, by design.
  Future<DropUploadInfo> info(String dropId) async {
    final body = await _client.get('/v1/uploads/$dropId');
    return DropUploadInfo(
      open: body['open'] as bool? ?? false,
      maxBytes: (body['max_bytes'] as num?)?.toInt() ?? 0,
      passwordRequired: body['password_required'] as bool? ?? true,
    );
  }

  /// `POST /v1/uploads/{id}/initiate` — reserve a slot, get a bounded
  /// presigned PUT.
  ///
  /// [byteCount] is a commitment, not a hint: the server bounds the
  /// presigned URL by it, so uploading more than declared fails at
  /// storage.
  ///
  /// **The slot is consumed here, not at commit.** Abandoning an upload
  /// costs the owner one of their allowance, so do not call this until
  /// the user has actually chosen a file.
  Future<DropUploadTicket> initiate({
    required String dropId,
    required String password,
    required int byteCount,
  }) async {
    final body = await _client.post(
      '/v1/uploads/$dropId/initiate',
      body: <String, dynamic>{'password': password, 'byte_count': byteCount},
    );
    return DropUploadTicket(
      transferId: body['transfer_id'] as String,
      storageKey: body['storage_key'] as String,
      uploadUrl: body['upload_url'] as String,
    );
  }

  /// `POST /v1/uploads/{id}/commit` — hand over the envelope.
  ///
  /// The password is required again: commit is a separate request, and
  /// without it anyone who guessed a pending transfer id could complete
  /// someone else's upload with their own envelope.
  Future<int> commit({
    required String dropId,
    required String password,
    required String transferId,
    required String blobSha256Hex,
    required String encHeaderB64,
    required String signatureB64,
    required String wrappedKeyB64,
    required String senderIdentityPubB64,
    required String senderSigningPubB64,
    int cryptoSuite = 1,
  }) async {
    final body = await _client.post(
      '/v1/uploads/$dropId/commit',
      body: <String, dynamic>{
        'password': password,
        'transfer_id': transferId,
        'blob_sha256': blobSha256Hex,
        'enc_header': encHeaderB64,
        'signature': signatureB64,
        'wrapped_key': wrappedKeyB64,
        'sender_identity_pub': senderIdentityPubB64,
        'sender_signing_pub': senderSigningPubB64,
        'crypto_suite': cryptoSuite,
      },
    );
    return (body['byte_count'] as num).toInt();
  }
}

class DropUploadInfo {
  const DropUploadInfo({
    required this.open,
    required this.maxBytes,
    required this.passwordRequired,
  });
  final bool open;
  final int maxBytes;
  final bool passwordRequired;
}

class DropUploadTicket {
  const DropUploadTicket({
    required this.transferId,
    required this.storageKey,
    required this.uploadUrl,
  });
  final String transferId;
  final String storageKey;
  final String uploadUrl;
}
