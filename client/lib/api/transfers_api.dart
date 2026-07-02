import 'api_client.dart';

/// `/v1/transfers/*` client (M2 core loop, spec §5.2 / §5.3).
///
/// The server treats `wrapped_key`, `enc_header`, and `signature` as
/// opaque bytes; the client is the only party that reads/writes them.
/// Everything on the wire is base64-encoded per the server schema.
class TransfersApi {
  const TransfersApi(this._client);
  final ApiClient _client;

  /// POST `/v1/transfers/initiate` — server allocates a `storage_key`,
  /// returns a presigned PUT URL for R2, and stamps `expires_at`.
  Future<InitiateTransferResponse> initiate({
    required String recipientId,
    required int byteCount,
    required String blobSha256Hex,
    required String wrappedKeyB64,
    required String encHeaderB64,
    required String signatureB64,
    int cryptoSuite = 1,
    int maxDownloads = 1,
  }) async {
    final body = await _client.post(
      '/v1/transfers/initiate',
      authed: true,
      body: {
        'mode': 'app',
        'recipient_id': recipientId,
        'byte_count': byteCount,
        'blob_sha256': blobSha256Hex,
        'crypto_suite': cryptoSuite,
        'wrapped_key': wrappedKeyB64,
        'enc_header': encHeaderB64,
        'signature': signatureB64,
        'max_downloads': maxDownloads,
      },
    );
    final multipart = body['multipart'];
    if (multipart != null) {
      throw StateError(
        'Server returned a multipart plan; M2 client only handles '
        'single-shot PUT uploads. Try a smaller file.',
      );
    }
    return InitiateTransferResponse(
      transferId: body['transfer_id'] as String,
      storageKey: body['storage_key'] as String,
      uploadUrl: body['upload_url'] as String,
    );
  }

  /// POST `/v1/transfers/{id}/commit` — server does R2 HEAD, measures
  /// the real byte_count, charges the sender's quota, and marks
  /// `uploaded`.
  Future<CommitTransferResponse> commit(String transferId) async {
    final body = await _client.post(
      '/v1/transfers/$transferId/commit',
      authed: true,
    );
    return CommitTransferResponse(
      status: body['status'] as String,
      byteCount: (body['byte_count'] as num).toInt(),
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
    );
  }

  /// POST `/v1/transfers/{id}/ack` — recipient signals success, server
  /// enqueues the R2 delete (burn-after-read) on the Redis queue.
  Future<String> ack(String transferId) async {
    final body = await _client.post(
      '/v1/transfers/$transferId/ack',
      authed: true,
    );
    return body['status'] as String;
  }
}

// --- domain types --------------------------------------------------------

class InitiateTransferResponse {
  const InitiateTransferResponse({
    required this.transferId,
    required this.storageKey,
    required this.uploadUrl,
  });
  final String transferId;
  final String storageKey;
  final String uploadUrl;
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
  });
  final String downloadUrl;
  final String? wrappedKeyB64; // null in link mode (M5)
  final String signatureB64;
  final String blobSha256Hex;
  final String encHeaderB64;
  final int cryptoSuite;
}

