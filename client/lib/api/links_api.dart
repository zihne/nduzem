import 'api_client.dart';

/// `/v1/links/*` client (ADR-0010). All endpoints are unauthenticated
/// — possession of the transfer id (UUID) is the access token, with
/// the optional link password as a second factor for the download
/// call. The URL fragment (K_file) never travels to the server.
class LinksApi {
  const LinksApi(this._client);
  final ApiClient _client;

  /// `GET /v1/links/{id}` — public info about a link-mode transfer.
  /// Returns the state flags the receive screen needs to decide what
  /// to render (missing, expired, consumed, password gate) plus the
  /// enc_header when the transfer is still downloadable.
  Future<LinkInfo> info(String transferId) async {
    final body = await _client.get('/v1/links/$transferId');
    return LinkInfo(
      transferId: body['transfer_id'] as String,
      exists: body['exists'] as bool? ?? false,
      expired: body['expired'] as bool? ?? false,
      consumed: body['consumed'] as bool? ?? false,
      passwordRequired: body['password_required'] as bool? ?? false,
      encHeaderB64: body['enc_header'] as String?,
      cryptoSuite: (body['crypto_suite'] as num?)?.toInt(),
      byteCount: (body['byte_count'] as num?)?.toInt(),
      expiresAt: body['expires_at'] == null
          ? null
          : DateTime.parse(body['expires_at'] as String),
    );
  }

  /// `POST /v1/links/{id}/download` — presigned URL + signature +
  /// enc_header. Optional [password] is the link's out-of-band
  /// password; a 401 comes back if it's wrong or missing when
  /// required. Each successful call increments `download_count`, so
  /// the caller should have committed to actually downloading the
  /// ciphertext before invoking this.
  Future<LinkDownload> download(
    String transferId, {
    String? password,
  }) async {
    final body = await _client.post(
      '/v1/links/$transferId/download',
      body: <String, dynamic>{
        if (password != null) 'link_password': password,
      },
    );
    return LinkDownload(
      downloadUrl: body['download_url'] as String,
      signatureB64: body['signature'] as String,
      blobSha256Hex: body['blob_sha256'] as String,
      encHeaderB64: body['enc_header'] as String,
      cryptoSuite: (body['crypto_suite'] as num).toInt(),
    );
  }

  /// `POST /v1/links/{id}/ack` — burn trigger. Idempotent. For
  /// `max_downloads > 1` links this is informational until the cap
  /// is hit; for the default `max_downloads == 1` it fires the
  /// burn immediately.
  /// `password` is required for password-protected links: acking is a
  /// state change (it can flip the transfer to DELETED and trigger the
  /// burn), so the server now demands the same secret as `/download`.
  /// Null for unprotected links, which still ack with an empty body.
  Future<String> ack(String transferId, {String? password}) async {
    final body = await _client.post(
      '/v1/links/$transferId/ack',
      body: password == null ? null : {'link_password': password},
    );
    return body['status'] as String;
  }
}

/// Response of `GET /v1/links/{id}`. Envelope fields
/// ([encHeaderB64], [cryptoSuite], [byteCount], [expiresAt]) are
/// populated ONLY when the transfer is still downloadable — the
/// server hides them once burn/expiry has fired to avoid leaking
/// metadata post-consumption.
class LinkInfo {
  const LinkInfo({
    required this.transferId,
    required this.exists,
    required this.expired,
    required this.consumed,
    required this.passwordRequired,
    this.encHeaderB64,
    this.cryptoSuite,
    this.byteCount,
    this.expiresAt,
  });
  final String transferId;
  final bool exists;
  final bool expired;
  final bool consumed;
  final bool passwordRequired;
  final String? encHeaderB64;
  final int? cryptoSuite;
  final int? byteCount;
  final DateTime? expiresAt;

  /// True iff a client can proceed to `POST /download` right now
  /// (assuming they can supply the password when required).
  bool get downloadable => exists && !expired && !consumed;
}

class LinkDownload {
  const LinkDownload({
    required this.downloadUrl,
    required this.signatureB64,
    required this.blobSha256Hex,
    required this.encHeaderB64,
    required this.cryptoSuite,
  });
  final String downloadUrl;

  /// Sender's Ed25519 signature over `blob_sha256`. Wire-compatible
  /// with the app-mode `DownloadTransferResponse.signature`, but
  /// link mode has no sender identity to verify against so the
  /// in-app link receive currently ignores this (ADR-0010).
  final String signatureB64;
  final String blobSha256Hex;
  final String encHeaderB64;
  final int cryptoSuite;
}
