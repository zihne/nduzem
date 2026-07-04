import 'api_client.dart';

/// `/v1/transfers/*` client (M2 core loop + M4 multipart, spec §5.2 / §5.3).
///
/// The server treats `wrapped_key`, `enc_header`, and `signature` as
/// opaque bytes; the client is the only party that reads/writes them.
/// Everything on the wire is base64-encoded per the server schema.
///
/// M4: `/initiate` may now return either a single-shot response
/// (`uploadUrl` populated) or a `multipart` plan (per-part presigned
/// URLs). See [InitiateTransferResponse] for both shapes.
class TransfersApi {
  const TransfersApi(this._client);
  final ApiClient _client;

  /// POST `/v1/transfers/initiate` — either `app` mode (recipient has
  /// an account, K_file sealed to their identity_pub) or `link` mode
  /// (recipient has no account, K_file lives in the URL fragment —
  /// server never sees it). Server-side response shape depends on
  /// declared byte_count: single-shot (M2 path) or multipart (M4
  /// path, server ADR-0012). The two shapes are represented in the
  /// same [InitiateTransferResponse] — exactly one of `uploadUrl` /
  /// `multipart` is populated.
  ///
  /// App-mode required: `recipientId`, `wrappedKeyB64`.
  /// Link-mode required: neither. Optional: `linkPassword` (adds an
  /// out-of-band gate at download time), `recipientEmail` (stored
  /// server-side as a blind index for a future "links sent to me"
  /// inbox — see server ADR-0014).
  Future<InitiateTransferResponse> initiate({
    required String mode,
    required int byteCount,
    required String blobSha256Hex,
    required String encHeaderB64,
    required String signatureB64,
    String? recipientId,
    String? wrappedKeyB64,
    String? linkPassword,
    String? recipientEmail,
    int cryptoSuite = 1,
    int maxDownloads = 1,
  }) async {
    assert(mode == 'app' || mode == 'link', 'unknown mode: $mode');
    assert(
      mode != 'app' || (recipientId != null && wrappedKeyB64 != null),
      'app mode requires recipientId + wrappedKeyB64',
    );
    final payload = <String, dynamic>{
      'mode': mode,
      'byte_count': byteCount,
      'blob_sha256': blobSha256Hex,
      'crypto_suite': cryptoSuite,
      'enc_header': encHeaderB64,
      'signature': signatureB64,
      'max_downloads': maxDownloads,
    };
    if (recipientId != null) payload['recipient_id'] = recipientId;
    if (wrappedKeyB64 != null) payload['wrapped_key'] = wrappedKeyB64;
    if (linkPassword != null) payload['link_password'] = linkPassword;
    if (recipientEmail != null) payload['recipient_email'] = recipientEmail;

    final body = await _client.post(
      '/v1/transfers/initiate',
      authed: true,
      body: payload,
    );
    final multipartJson = body['multipart'];
    MultipartUploadPlan? multipart;
    if (multipartJson != null) {
      multipart = MultipartUploadPlan.fromJson(
        multipartJson as Map<String, dynamic>,
      );
    }
    return InitiateTransferResponse(
      transferId: body['transfer_id'] as String,
      storageKey: body['storage_key'] as String,
      uploadUrl: body['upload_url'] as String?,
      multipart: multipart,
    );
  }

  /// POST `/v1/transfers/{id}/commit`. Body is required for multipart
  /// (per-part ETags) and omitted for single-shot. The server calls
  /// `CompleteMultipartUpload` under the hood on the multipart branch
  /// before HEADing for the real byte_count.
  Future<CommitTransferResponse> commit(
    String transferId, {
    List<CommitPart>? parts,
  }) async {
    final body = await _client.post(
      '/v1/transfers/$transferId/commit',
      authed: true,
      body: parts == null
          ? null
          : {
              'parts': [
                for (final p in parts)
                  {'part_number': p.partNumber, 'etag': p.etag},
              ],
            },
    );
    return CommitTransferResponse(
      status: body['status'] as String,
      byteCount: (body['byte_count'] as num).toInt(),
    );
  }

  /// POST `/v1/transfers/{id}/abort` — client-initiated cleanup of an
  /// in-flight multipart upload. Idempotent per server ADR-0012, so a
  /// double-abort on race conditions is safe. Should be called when
  /// the user cancels a large upload or when any post-`/initiate`
  /// step throws.
  Future<void> abort(String transferId) async {
    await _client.post(
      '/v1/transfers/$transferId/abort',
      authed: true,
    );
  }

  /// GET `/v1/transfers/inbox` — list transfers the caller is the
  /// recipient of, that are still in `uploaded` state.
  Future<List<InboxItem>> inbox() async {
    // Server returns a JSON array; ApiClient wraps it as {raw: [...]}.
    final body = await _client.get('/v1/transfers/inbox', authed: true);
    final raw = body['raw'] as List<dynamic>? ?? <dynamic>[];
    return raw
        .cast<Map<String, dynamic>>()
        .map(InboxItem.fromJson)
        .toList(growable: false);
  }

  /// POST `/v1/transfers/{id}/download` — increments the download
  /// counter, returns a presigned GET URL + the opaque envelope.
  Future<DownloadTransferResponse> requestDownload(String transferId) async {
    final body = await _client.post(
      '/v1/transfers/$transferId/download',
      authed: true,
    );
    return DownloadTransferResponse(
      downloadUrl: body['download_url'] as String,
      wrappedKeyB64: body['wrapped_key'] as String?,
      signatureB64: body['signature'] as String,
      blobSha256Hex: body['blob_sha256'] as String,
      encHeaderB64: body['enc_header'] as String,
      cryptoSuite: (body['crypto_suite'] as num).toInt(),
      senderIdentityPubB64: body['sender_identity_pub'] as String?,
      senderSigningPubB64: body['sender_signing_pub'] as String?,
      senderId: body['sender_id'] as String?,
      senderHandle: body['sender_handle'] as String?,
    );
  }

  /// POST `/v1/transfers/{id}/ack` — recipient signals success, server
  /// enqueues the burn-after-read delete of the ciphertext object.
  Future<String> ack(String transferId) async {
    final body = await _client.post(
      '/v1/transfers/$transferId/ack',
      authed: true,
    );
    return body['status'] as String;
  }
}

// --- domain types --------------------------------------------------------

/// Two-shape response from `/initiate` (server ADR-0012). Exactly one
/// of [uploadUrl] and [multipart] is non-null. Callers use the null
/// check as the branch predicate — no explicit tag field.
class InitiateTransferResponse {
  const InitiateTransferResponse({
    required this.transferId,
    required this.storageKey,
    required this.uploadUrl,
    required this.multipart,
  });
  final String transferId;
  final String storageKey;

  /// Single-shot presigned PUT URL. Non-null iff `byte_count`
  /// declared at initiate ≤ server's `MULTIPART_THRESHOLD_BYTES`.
  final String? uploadUrl;

  /// Per-part presigned URLs + upload id. Non-null iff `byte_count`
  /// > threshold. Client PUTs each part sequentially, captures the
  /// per-part ETag, then calls `/commit` with the parts list.
  final MultipartUploadPlan? multipart;
}

/// One presigned URL per part number. Parts are 1-indexed per the S3
/// multipart contract; part_number matches what will be sent back on
/// `/commit`.
class MultipartUploadPlan {
  const MultipartUploadPlan({
    required this.uploadId,
    required this.partSize,
    required this.parts,
  });

  /// Opaque server-side identifier for the S3 multipart upload
  /// session. Round-tripped to `/abort` / `/commit`.
  final String uploadId;

  /// Bytes per non-final part. The last part may be smaller; every
  /// other part must be exactly `partSize` bytes. S3's minimum is
  /// 5 MiB — server enforces that at initiate.
  final int partSize;
  final List<MultipartPartUrl> parts;

  static MultipartUploadPlan fromJson(Map<String, dynamic> m) =>
      MultipartUploadPlan(
        uploadId: m['upload_id'] as String,
        partSize: (m['part_size'] as num).toInt(),
        parts: (m['parts'] as List<dynamic>)
            .cast<Map<String, dynamic>>()
            .map(MultipartPartUrl.fromJson)
            .toList(growable: false),
      );
}

class MultipartPartUrl {
  const MultipartPartUrl({required this.partNumber, required this.url});
  final int partNumber;
  final String url;

  static MultipartPartUrl fromJson(Map<String, dynamic> m) =>
      MultipartPartUrl(
        partNumber: (m['part_number'] as num).toInt(),
        url: m['url'] as String,
      );
}

/// One part's ETag as reported by S3 in the response header. Sent
/// back on `/commit` so the server can call `CompleteMultipartUpload`.
class CommitPart {
  const CommitPart({required this.partNumber, required this.etag});
  final int partNumber;
  final String etag;
}

class CommitTransferResponse {
  const CommitTransferResponse({required this.status, required this.byteCount});
  final String status;
  final int byteCount;
}

class InboxItem {
  const InboxItem({
    required this.transferId,
    required this.senderId,
    required this.senderHandle,
    required this.encHeaderB64,
    required this.cryptoSuite,
    required this.byteCount,
    required this.createdAt,
    required this.expiresAt,
  });

  final String transferId;
  final String? senderId;
  final String? senderHandle;
  final String encHeaderB64;
  final int cryptoSuite;
  final int byteCount;
  final DateTime createdAt;
  final DateTime expiresAt;

  static InboxItem fromJson(Map<String, dynamic> m) => InboxItem(
        transferId: m['transfer_id'] as String,
        senderId: m['sender_id'] as String?,
        senderHandle: m['sender_handle'] as String?,
        encHeaderB64: m['enc_header'] as String,
        cryptoSuite: (m['crypto_suite'] as num).toInt(),
        byteCount: (m['byte_count'] as num).toInt(),
        createdAt: DateTime.parse(m['created_at'] as String),
        expiresAt: DateTime.parse(m['expires_at'] as String),
      );
}

class DownloadTransferResponse {
  const DownloadTransferResponse({
    required this.downloadUrl,
    required this.wrappedKeyB64,
    required this.signatureB64,
    required this.blobSha256Hex,
    required this.encHeaderB64,
    required this.cryptoSuite,
    required this.senderIdentityPubB64,
    required this.senderSigningPubB64,
    required this.senderId,
    required this.senderHandle,
  });
  final String downloadUrl;
  final String? wrappedKeyB64; // null in link mode (M5)
  final String signatureB64;
  final String blobSha256Hex;
  final String encHeaderB64;
  final int cryptoSuite;

  /// Sender's `identity_pub` (base64). Null when the sender has erased
  /// themselves (M9.5) or in link mode (M5). Lets the recipient
  /// recompute the sender's fingerprint locally and cross-check against
  /// prior OOB verification (ADR-0031).
  final String? senderIdentityPubB64;

  /// Sender's `signing_pub` (base64). Null in the same cases as
  /// [senderIdentityPubB64]. Verifies the Ed25519 `signatureB64` over
  /// `blobSha256Hex` without a second lookup round-trip (ADR-0031).
  final String? senderSigningPubB64;

  /// Sender's account id (uuid, as string). Null in link mode and for
  /// senders that have erased themselves. Used by the receive screen
  /// to log a short-form sender id to on-device transfer history
  /// (client ADR-0007) alongside [senderHandle].
  final String? senderId;

  /// Sender's decrypted handle. Null in link mode and for senders that
  /// have erased themselves (or never set a handle). Logged to
  /// on-device transfer history so past receives display as `@alice`
  /// rather than a bare UUID prefix (client ADR-0007).
  final String? senderHandle;
}

