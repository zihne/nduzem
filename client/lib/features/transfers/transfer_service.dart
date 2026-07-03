import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../api/api_client.dart';
import '../../api/transfers_api.dart';
import '../../api/users_api.dart';
import '../../crypto/envelope.dart';
import '../../crypto/file_crypto.dart';
import '../../crypto/sealed_box.dart';
import '../../storage/secure_storage.dart';

/// Orchestrates the send + receive flows end-to-end (spec §5.2/§5.3).
///
/// M4 changes (ADR-0003):
///
/// - **Send** now accepts multipart `/initiate` responses: splits the
///   ciphertext into `part_size`-byte chunks, sequentially PUTs each,
///   captures per-part ETags, then commits with the parts list.
/// - Optional `onProgress` callback fires after each part upload so
///   the UI can render a bar. On the M2 single-shot path it fires
///   exactly once at 100 % after the single PUT succeeds.
/// - Optional [CancelToken] lets the UI cancel a large upload; the
///   service POSTs `/abort` before propagating.
/// - Ciphertext format is now `crypto_secretstream_xchacha20poly1305`
///   in the OS4S container (see [FileCrypto]).
///
/// **Sender-signature verification** at receive: server surfaces
/// `sender_signing_pub` on `/download`, so [receive] verifies the
/// Ed25519 detached signature over `blob_sha256` before decrypting.
/// A mismatch is a hard block. When the sender has erased themselves
/// (M9.5), the pubkey is null → skip verification and note it on the
/// returned [DecryptedTransfer].
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

  /// Encrypt, upload, and commit a transfer. Handles both the M2
  /// single-shot path and the M4 multipart path — the server decides
  /// which one based on declared byte_count.
  ///
  /// `onProgress` fires with `(uploadedBytes, totalBytes)` after each
  /// part upload (single-shot: one final 100 % tick).
  ///
  /// `cancel` lets the caller interrupt between part PUTs. Cancels
  /// after `/initiate` POST `/abort` before propagating so R2's
  /// in-flight parts are cleaned up immediately.
  Future<SendResult> send({
    required UserLookup recipient,
    required Uint8List plaintext,
    required String filename,
    String? mime,
    void Function(int uploadedBytes, int totalBytes)? onProgress,
    CancelToken? cancel,
  }) async {
    // 1. Fresh K_file for this transfer.
    final fileKey = _fileCrypto.generateFileKey();

    // 2. Encrypt file body into the OS4S container + hash the wire bytes.
    final ciphertext = await _fileCrypto.encryptFile(
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

    // 6. Initiate on the server. Response is either single-shot or
    // multipart shape — same envelope, different upload path.
    final initiated = await _transfers.initiate(
      recipientId: recipient.userId,
      byteCount: ciphertext.length,
      blobSha256Hex: blobSha256,
      wrappedKeyB64: base64Encode(sealed),
      encHeaderB64: base64Encode(encHeader),
      signatureB64: base64Encode(signature),
    );

    // 7 + 8. Upload + commit. Anything from here that throws MUST call
    // /abort on the multipart branch so R2 doesn't hold in-flight
    // parts open until the server's 6-hour sweeper runs.
    try {
      if (initiated.multipart != null) {
        return await _sendMultipart(
          transferId: initiated.transferId,
          ciphertext: ciphertext,
          plan: initiated.multipart!,
          onProgress: onProgress,
          cancel: cancel,
        );
      }
      return await _sendSingleShot(
        transferId: initiated.transferId,
        ciphertext: ciphertext,
        uploadUrl: initiated.uploadUrl!,
        onProgress: onProgress,
        cancel: cancel,
      );
    } on Object {
      // Best-effort cleanup — a failure to abort still lets the
      // orphan sweeper reclaim in the background. Don't swallow the
      // outer exception, whatever it is, on abort failure.
      try {
        await _transfers.abort(initiated.transferId);
      } on Object {
        // ignore
      }
      rethrow;
    }
  }

  Future<SendResult> _sendSingleShot({
    required String transferId,
    required Uint8List ciphertext,
    required String uploadUrl,
    required void Function(int, int)? onProgress,
    required CancelToken? cancel,
  }) async {
    cancel?.throwIfCancelled();
    final putRes = await _httpClient.put(
      Uri.parse(uploadUrl),
      body: ciphertext,
    );
    if (putRes.statusCode < 200 || putRes.statusCode >= 300) {
      throw ApiException(
        statusCode: putRes.statusCode,
        message: 'Upload to storage failed (HTTP ${putRes.statusCode}).',
      );
    }
    onProgress?.call(ciphertext.length, ciphertext.length);

    cancel?.throwIfCancelled();
    final committed = await _transfers.commit(transferId);
    return SendResult(
      transferId: transferId,
      byteCountOnServer: committed.byteCount,
      status: committed.status,
    );
  }

  Future<SendResult> _sendMultipart({
    required String transferId,
    required Uint8List ciphertext,
    required MultipartUploadPlan plan,
    required void Function(int, int)? onProgress,
    required CancelToken? cancel,
  }) async {
    final parts = <CommitPart>[];
    var uploadedBytes = 0;
    for (final partUrl in plan.parts) {
      cancel?.throwIfCancelled();
      // Slice the ciphertext for this part. Non-final parts are
      // exactly `plan.partSize` bytes per S3 contract; the last part
      // may be shorter (`plan.parts.length * plan.partSize` may exceed
      // ciphertext.length).
      final offset = (partUrl.partNumber - 1) * plan.partSize;
      if (offset >= ciphertext.length) {
        // We got more part URLs than actually needed — happens when
        // the ciphertext ended up smaller than the client's original
        // byte_count declaration. Safe to skip.
        continue;
      }
      final end = (offset + plan.partSize).clamp(0, ciphertext.length);
      final body = Uint8List.sublistView(ciphertext, offset, end);
      final res = await _httpClient.put(Uri.parse(partUrl.url), body: body);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw ApiException(
          statusCode: res.statusCode,
          message: 'Upload of part ${partUrl.partNumber} failed '
              '(HTTP ${res.statusCode}).',
        );
      }
      final etag = res.headers['etag'];
      if (etag == null || etag.isEmpty) {
        throw StateError(
          'Object storage did not return an ETag for part '
          '${partUrl.partNumber}; cannot commit multipart upload.',
        );
      }
      parts.add(CommitPart(partNumber: partUrl.partNumber, etag: etag));
      uploadedBytes += body.length;
      onProgress?.call(uploadedBytes, ciphertext.length);
    }

    cancel?.throwIfCancelled();
    final committed = await _transfers.commit(transferId, parts: parts);
    return SendResult(
      transferId: transferId,
      byteCountOnServer: committed.byteCount,
      status: committed.status,
    );
  }

  // --- INBOX ------------------------------------------------------------

  Future<List<InboxItem>> inbox() => _transfers.inbox();

  // --- RECEIVE ----------------------------------------------------------

  /// Downloads bytes and decrypts them — but does **not** touch the disk.
  /// The screen holds the decrypted [DecryptedTransfer.plaintext] in
  /// memory and delegates the "where to save" question to the user via
  /// `file_picker.saveFile` (or share sheet, etc.). Keeping the save
  /// path out of this service:
  ///
  ///   - lets the user pick a location they can actually browse to (the
  ///     app-documents dir is sandboxed on Android — not visible from
  ///     the Files app or a file manager without root);
  ///   - keeps this service free of a `path_provider` dependency it
  ///     otherwise wouldn't need.
  ///
  /// Callers should invoke [ack] on the returned `transferId` once the
  /// user has actually saved / opened the file — losing the plaintext
  /// after ack is a data-loss cliff, so the ack is a separate call.
  Future<DecryptedTransfer> receive({required String transferId}) async {
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

    // 3b. Sender signature. If the server surfaces `sender_signing_pub`
    // (present iff the sender still has a live account — see
    // ADR-0031), verify the Ed25519 detached signature over the raw
    // bytes of `blob_sha256` before decrypting anything. A bad signature
    // is fatal: it means either the file was tampered with or the
    // server is lying about who sent it — either way, we refuse.
    var senderSignatureVerified = false;
    final senderSigningPubB64 = dl.senderSigningPubB64;
    if (senderSigningPubB64 != null) {
      final ok = _envelope.verifyBlobSha256Signature(
        blobSha256Hex: dl.blobSha256Hex,
        signature: base64Decode(dl.signatureB64),
        senderSigningPublic: base64Decode(senderSigningPubB64),
      );
      if (!ok) {
        throw StateError(
          "Sender's signature does not verify against their signing_pub "
          '— refusing to decrypt.',
        );
      }
      senderSignatureVerified = true;
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

    // 6. Decrypt body via the M4 chunked-secretstream reader. Throws
    // FormatException if the OS4S magic prefix is missing (older
    // sender client) and SodiumException on any AEAD failure.
    final plaintext = await _fileCrypto.decryptFile(
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

    return DecryptedTransfer(
      transferId: transferId,
      // Sanitise the filename so a malicious sender can't inject path
      // separators / suspicious names into the eventual save dialog.
      filename: _sanitiseFilename(header.filename, transferId),
      mime: header.mime,
      plaintext: plaintext,
      byteCount: plaintext.length,
      senderSignatureVerified: senderSignatureVerified,
      senderIdentityPubB64: dl.senderIdentityPubB64,
    );
  }

  /// POST /ack — server enqueues the burn-after-read delete of the
  /// ciphertext object.
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
}

// --- cancellation --------------------------------------------------------

/// Cheap cancel signal owned by the UI. `cancel()` flips the flag;
/// the send loop checks between part PUTs and throws
/// [SendCancelledException]. The service catches it in the /abort
/// finally and rethrows.
class CancelToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() {
    _cancelled = true;
  }

  void throwIfCancelled() {
    if (_cancelled) {
      throw SendCancelledException();
    }
  }
}

class SendCancelledException implements Exception {
  const SendCancelledException();
  @override
  String toString() => 'Send cancelled by user.';
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

/// Result of a successful download + decrypt. The bytes live in memory
/// until the caller writes them somewhere the user chose.
class DecryptedTransfer {
  const DecryptedTransfer({
    required this.transferId,
    required this.filename,
    required this.mime,
    required this.plaintext,
    required this.byteCount,
    required this.senderSignatureVerified,
    required this.senderIdentityPubB64,
  });
  final String transferId;
  final String filename;
  final String? mime;
  final Uint8List plaintext;
  final int byteCount;

  /// True when the recipient verified the sender's Ed25519 detached
  /// signature over `blob_sha256` against `senderSigningPub` at receive
  /// time. False when the sender has erased themselves and their
  /// pubkey was withheld — in that case the signature was NOT checked
  /// and the UI should note it (rather than pretending it was safe).
  final bool senderSignatureVerified;

  /// Sender's `identity_pub` (base64), threaded through so the receive
  /// screen can offer "verify this sender now" with the fingerprint
  /// pre-computed. Null when the sender has erased themselves.
  final String? senderIdentityPubB64;
}
