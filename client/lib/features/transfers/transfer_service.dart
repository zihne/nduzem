import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../api/api_client.dart';
import '../../api/transfers_api.dart';
import '../../api/users_api.dart';
import '../../crypto/envelope.dart';
import '../../crypto/file_crypto.dart';
import '../../crypto/sealed_box.dart';
import '../../storage/secure_storage.dart';

/// Orchestrates the M2 send + receive flows end-to-end (spec §5.2/§5.3).
///
/// The service is stateless — every method takes the pieces it needs and
/// returns a small result. Screens hold the UI-level state (progress,
/// error, chosen file, …).
///
/// **Send** (single-PUT for M2):
///   1. Look up recipient's pubkeys.
///   2. Generate `K_file`; encrypt file body + build enc_header.
///   3. Seal `K_file` for the recipient.
///   4. Sign SHA-256(ciphertext) with our signing_priv.
///   5. POST /initiate → get presigned URL.
///   6. PUT ciphertext to R2.
///   7. POST /commit.
///
/// **Receive**:
///   1. POST /download → presigned GET URL + envelope.
///   2. GET the ciphertext.
///   3. Verify SHA-256(ciphertext) matches `blob_sha256`.
///   4. Unseal `wrapped_key` → K_file.
///   5. Decrypt enc_header → filename/mime/size.
///   6. Decrypt body → plaintext.
///   7. Write to disk.
///   8. POST /ack.
///
/// **Sender-signature verification** at receive is intentionally NOT
/// implemented in M2. The server's download response carries the
/// signature but not the sender's `signing_pub`, and
/// `/v1/users/lookup` currently only accepts email/handle. When the
/// server surfaces sender-pubkeys (either by extending lookup or by
/// enriching the download response), this service will start
/// verifying. Documented so nobody accidentally reads the current lack
/// of a `verify` call as a security omission we didn't notice.
class TransferService {
  const TransferService({
    required TransfersApi transfers,
    required UsersApi users,
    required SealedBox sealedBox,
    required FileCrypto fileCrypto,
    required Envelope envelope,
    required SecureStore storage,
    http.Client? httpClient,
  })  : _transfers = transfers,
        _users = users,
        _sealedBox = sealedBox,
        _fileCrypto = fileCrypto,
        _envelope = envelope,
        _storage = storage,
        _http = httpClient;

  final TransfersApi _transfers;
  final UsersApi _users;
  final SealedBox _sealedBox;
  final FileCrypto _fileCrypto;
  final Envelope _envelope;
  final SecureStore _storage;
  final http.Client? _http;

  http.Client get _httpClient => _http ?? http.Client();

  // --- lookup helper (used by the UI before sealing) --------------------

  Future<UserLookup> lookupRecipient({String? email, String? handle}) =>
      _users.lookup(email: email, handle: handle);

  // --- SEND -------------------------------------------------------------

  Future<SendResult> send({
    required UserLookup recipient,
    required Uint8List plaintext,
    required String filename,
    String? mime,
  }) async {
    // 1. Fresh K_file for this transfer.
    final fileKey = _fileCrypto.generateFileKey();

    // 2. Encrypt file body + compute the hash the server + envelope share.
    final ciphertext = _fileCrypto.encryptFile(
      plaintext: plaintext,
      key: fileKey,
    );
    final blobSha256 = _fileCrypto.sha256Hex(ciphertext);

    // 3. Build enc_header (encrypted metadata blob).
    final encHeader = _envelope.buildEncHeader(
      filename: filename,
      mime: mime,
      plaintextLength: plaintext.length,
      blobSha256Hex: blobSha256,
      fileKey: fileKey,
    );

    // 4. Seal K_file for the recipient (crypto_box_seal).
    final sealed = _sealedBox.seal(
      message: fileKey,
      recipientIdentityPublic: recipient.identityPublic,
    );

    // 5. Sign blob_sha256 with our Ed25519 signing_priv.
    final signingPriv = await _storage.readBytes(SecureStore.kSigningPrivate);
    if (signingPriv == null) {
      throw StateError(
        'No signing private key on device. Register or sign in from the '
        'device where this account was created.',
      );
    }
    final signature = _envelope.signBlobSha256(
      blobSha256Hex: blobSha256,
      signingPrivate: signingPriv,
    );

    // 6. Initiate on the server.
    final initiated = await _transfers.initiate(
      recipientId: recipient.userId,
      byteCount: ciphertext.length,
      blobSha256Hex: blobSha256,
      wrappedKeyB64: base64Encode(sealed),
      encHeaderB64: base64Encode(encHeader),
      signatureB64: base64Encode(signature),
    );

    // 7. PUT the ciphertext to R2.
    final putRes = await _httpClient.put(
      Uri.parse(initiated.uploadUrl),
      body: ciphertext,
    );
    if (putRes.statusCode < 200 || putRes.statusCode >= 300) {
      throw ApiException(
        statusCode: putRes.statusCode,
        message: 'Upload to storage failed (HTTP ${putRes.statusCode}).',
      );
    }

    // 8. Commit — server HEADs, measures, charges quota.
    final committed = await _transfers.commit(initiated.transferId);
    return SendResult(
      transferId: initiated.transferId,
      byteCountOnServer: committed.byteCount,
      status: committed.status,
    );
  }

  // --- INBOX ------------------------------------------------------------

  Future<List<InboxItem>> inbox() => _transfers.inbox();

  // --- RECEIVE ----------------------------------------------------------

  /// Fetches the download response, downloads bytes, decrypts, and
  /// writes to `destDir`. Returns a [ReceiveResult] with the saved path.
  ///
  /// Callers should invoke [ack] on the returned `transferId` once the
  /// user has actually saved / opened the file — losing the plaintext
  /// after ack is a data-loss cliff, so the ack is a separate call.
  Future<ReceiveResult> receive({
    required String transferId,
    required Directory destDir,
  }) async {
    // 1. Get presigned URL + envelope.
    final dl = await _transfers.requestDownload(transferId);
    if (dl.wrappedKeyB64 == null) {
      throw StateError(
        'This transfer is link-mode (wrapped_key is null). Link mode is '
        'M5 client work.',
      );
    }

    // 2. Download the ciphertext.
    final getRes = await _httpClient.get(Uri.parse(dl.downloadUrl));
    if (getRes.statusCode < 200 || getRes.statusCode >= 300) {
      throw ApiException(
        statusCode: getRes.statusCode,
        message: 'Download from storage failed (HTTP ${getRes.statusCode}).',
      );
    }
    final ciphertext = getRes.bodyBytes;

    // 3. Integrity: server-reported hash must match the ciphertext we
    // just received. Cheap sanity check before we spend CPU on the AEAD.
    final localHash = _fileCrypto.sha256Hex(ciphertext);
    if (localHash != dl.blobSha256Hex) {
      throw StateError(
        'Downloaded ciphertext hash does not match the server-reported '
        'blob_sha256 — refusing to decrypt.',
      );
    }

    // 4. Unseal wrapped_key with our identity keypair.
    final identityPriv = await _storage.readBytes(SecureStore.kIdentityPrivate);
    final identityPub = await _storage.readBytes(SecureStore.kIdentityPublic);
    if (identityPriv == null || identityPub == null) {
      throw StateError(
        'No identity keypair on device. Sign in from the device where '
        'this account was created to decrypt received transfers.',
      );
    }
    final fileKey = _sealedBox.sealOpen(
      ciphertext: base64Decode(dl.wrappedKeyB64!),
      recipientIdentityPublic: identityPub,
      recipientIdentityPrivate: identityPriv,
    );

    // 5. Decrypt enc_header.
    final header = _envelope.openEncHeader(
      encHeader: base64Decode(dl.encHeaderB64),
      fileKey: fileKey,
    );

    // 6. Decrypt body.
    final plaintext = _fileCrypto.decryptFile(
      ciphertextBlob: ciphertext,
      key: fileKey,
    );

    // Guardrail: what the header claimed the length would be MUST match
    // what we actually decrypted. Any mismatch is a tampering signal.
    if (plaintext.length != header.plaintextLength) {
      throw StateError(
        'Decrypted plaintext length (${plaintext.length}) does not match '
        'the header claim (${header.plaintextLength}).',
      );
    }

    // 7. Write to disk. Sanitise the filename so a malicious sender
    // cannot escape destDir via `../` or absolute paths.
    final safeName = _sanitiseFilename(header.filename, transferId);
    final path = _uniqueDestPath(destDir, safeName);
    final file = File(path);
    await file.writeAsBytes(plaintext, flush: true);

    return ReceiveResult(
      transferId: transferId,
      filename: safeName,
      mime: header.mime,
      savedPath: path,
      byteCount: plaintext.length,
    );
  }

  /// POST /ack — server enqueues the R2 delete (burn-after-read).
  Future<String> ack(String transferId) => _transfers.ack(transferId);

  // --- helpers ---------------------------------------------------------

  String _sanitiseFilename(String candidate, String transferId) {
    // Strip directory components AND anything that isn't alphanumeric,
    // dot, dash, underscore, space. Empty → fallback per transfer id.
    final basename = candidate.split(RegExp(r'[\\/]')).last;
    final cleaned = basename.replaceAll(RegExp(r'[^A-Za-z0-9._\- ]'), '_');
    if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') {
      return 'opaqueshare-$transferId';
    }
    return cleaned;
  }

  String _uniqueDestPath(Directory destDir, String name) {
    var candidate = File('${destDir.path}/$name');
    if (!candidate.existsSync()) return candidate.path;
    // Suffix with (1), (2), … until a free name is found.
    final dot = name.lastIndexOf('.');
    final stem = dot < 0 ? name : name.substring(0, dot);
    final ext = dot < 0 ? '' : name.substring(dot);
    var i = 1;
    while (candidate.existsSync()) {
      candidate = File('${destDir.path}/$stem ($i)$ext');
      i++;
    }
    return candidate.path;
  }
}

// --- domain result types -------------------------------------------------

class SendResult {
  const SendResult({
    required this.transferId,
    required this.byteCountOnServer,
    required this.status,
  });
  final String transferId;
  final int byteCountOnServer;
  final String status;
}

class ReceiveResult {
  const ReceiveResult({
    required this.transferId,
    required this.filename,
    required this.mime,
    required this.savedPath,
    required this.byteCount,
  });
  final String transferId;
  final String filename;
  final String? mime;
  final String savedPath;
  final int byteCount;
}
