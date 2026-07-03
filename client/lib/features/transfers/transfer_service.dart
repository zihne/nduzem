import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

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

  /// Encrypt, upload, and commit a transfer. Streaming from disk:
  /// plaintext is read chunk-by-chunk from `plaintextPath` through
  /// secretstream into a temp file, then that temp file is uploaded
  /// part-by-part (multipart) or in one shot (< 5 MiB). Peak memory
  /// ≈ 8 MiB regardless of file size (ADR-0004).
  ///
  /// `onProgress` fires with `(phase, done, total)`:
  ///   - `SendPhase.encrypting`: `done` = plaintext bytes read,
  ///     `total` = `plaintextLength`.
  ///   - `SendPhase.uploading`: `done` = ciphertext bytes PUT,
  ///     `total` = final ciphertext size.
  ///
  /// `cancel` is checked between plaintext-read chunks and between
  /// part PUTs. Cancels after `/initiate` POST `/abort` before
  /// propagating so R2's in-flight parts are cleaned up immediately.
  Future<SendResult> send({
    required UserLookup recipient,
    required String plaintextPath,
    required int plaintextLength,
    required String filename,
    String? mime,
    void Function(SendPhase phase, int done, int total)? onProgress,
    CancelToken? cancel,
  }) async {
    // 1. Fresh K_file for this transfer.
    final fileKey = _fileCrypto.generateFileKey();

    // 2. Stream-encrypt plaintext → temp file, rolling SHA-256 in the
    // same pass. Peak memory ≈ one 64 KiB secretstream chunk.
    onProgress?.call(SendPhase.encrypting, 0, plaintextLength);
    final tempDir = await getTemporaryDirectory();
    final enc = await _fileCrypto.encryptFileToTempFile(
      plaintextPath: plaintextPath,
      key: fileKey,
      tempDir: tempDir,
      throwIfCancelled: cancel?.throwIfCancelled,
      onProgress: (done, total) =>
          onProgress?.call(SendPhase.encrypting, done, total),
    );

    final ciphertextFile = File(enc.ciphertextPath);
    try {
      // Post-encrypt / pre-upload phase — enc_header + seal + sign +
      // /initiate. On a multi-GB file the /initiate call presigns
      // ~700 URLs server-side and produces a ~90 KB response body,
      // easily a few seconds. Fire an indeterminate phase so the UI
      // doesn't sit at "Encrypting 100%" during that gap.
      onProgress?.call(SendPhase.preparing, 0, 0);

      // 3. Build enc_header (encrypted metadata blob).
      final encHeader = _envelope.buildEncHeader(
        filename: filename,
        mime: mime,
        plaintextLength: plaintextLength,
        blobSha256Hex: enc.blobSha256Hex,
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
        blobSha256Hex: enc.blobSha256Hex,
        signingPrivate: signingPriv,
      );

      // 6. Initiate on the server. Response is either single-shot or
      // multipart shape — same envelope, different upload path.
      final initiated = await _transfers.initiate(
        recipientId: recipient.userId,
        byteCount: enc.ciphertextLength,
        blobSha256Hex: enc.blobSha256Hex,
        wrappedKeyB64: base64Encode(sealed),
        encHeaderB64: base64Encode(encHeader),
        signatureB64: base64Encode(signature),
      );

      // 7 + 8. Upload + commit. Anything from here that throws MUST
      // call /abort on the multipart branch so R2 doesn't hold
      // in-flight parts open until the server's 6-hour sweeper runs.
      onProgress?.call(SendPhase.uploading, 0, enc.ciphertextLength);
      try {
        if (initiated.multipart != null) {
          return await _sendMultipartFromFile(
            transferId: initiated.transferId,
            ciphertextFile: ciphertextFile,
            ciphertextLength: enc.ciphertextLength,
            plan: initiated.multipart!,
            onProgress: (up, total) =>
                onProgress?.call(SendPhase.uploading, up, total),
            cancel: cancel,
          );
        }
        return await _sendSingleShotFromFile(
          transferId: initiated.transferId,
          ciphertextFile: ciphertextFile,
          ciphertextLength: enc.ciphertextLength,
          uploadUrl: initiated.uploadUrl!,
          onProgress: (up, total) =>
              onProgress?.call(SendPhase.uploading, up, total),
          cancel: cancel,
        );
      } on Object {
        // Best-effort cleanup — a failure to abort still lets the
        // orphan sweeper reclaim in the background. Don't swallow
        // the outer exception, whatever it is.
        try {
          await _transfers.abort(initiated.transferId);
        } on Object {
          // ignore
        }
        rethrow;
      }
    } finally {
      // Always drop the temp ciphertext file — success, cancel, or
      // failure. A process-kill leak is backstopped by the OS's
      // own cache reclamation.
      try {
        if (await ciphertextFile.exists()) {
          await ciphertextFile.delete();
        }
      } on Object {
        // ignore
      }
    }
  }

  Future<SendResult> _sendSingleShotFromFile({
    required String transferId,
    required File ciphertextFile,
    required int ciphertextLength,
    required String uploadUrl,
    required void Function(int, int)? onProgress,
    required CancelToken? cancel,
  }) async {
    cancel?.throwIfCancelled();
    // Under the 5 MiB threshold — fits comfortably in memory. Reading
    // the whole file is simpler than a streamed PUT and avoids the
    // `http.StreamedRequest` complications for a fast path that
    // doesn't need them.
    final body = await ciphertextFile.readAsBytes();
    final putRes = await _httpClient.put(Uri.parse(uploadUrl), body: body);
    if (putRes.statusCode < 200 || putRes.statusCode >= 300) {
      throw ApiException(
        statusCode: putRes.statusCode,
        message: 'Upload to storage failed (HTTP ${putRes.statusCode}).',
      );
    }
    onProgress?.call(ciphertextLength, ciphertextLength);

    cancel?.throwIfCancelled();
    final committed = await _transfers.commit(transferId);
    return SendResult(
      transferId: transferId,
      byteCountOnServer: committed.byteCount,
      status: committed.status,
    );
  }

  Future<SendResult> _sendMultipartFromFile({
    required String transferId,
    required File ciphertextFile,
    required int ciphertextLength,
    required MultipartUploadPlan plan,
    required void Function(int, int)? onProgress,
    required CancelToken? cancel,
  }) async {
    final raf = await ciphertextFile.open(mode: FileMode.read);
    try {
      final parts = <CommitPart>[];
      var uploadedBytes = 0;
      for (final partUrl in plan.parts) {
        cancel?.throwIfCancelled();
        final offset = (partUrl.partNumber - 1) * plan.partSize;
        if (offset >= ciphertextLength) {
          // Extra part URL beyond what we actually need. Safe skip.
          continue;
        }
        final remaining = ciphertextLength - offset;
        final len = remaining < plan.partSize ? remaining : plan.partSize;
        await raf.setPosition(offset);
        final body = await raf.read(len);
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
        onProgress?.call(uploadedBytes, ciphertextLength);
      }

      cancel?.throwIfCancelled();
      final committed = await _transfers.commit(transferId, parts: parts);
      return SendResult(
        transferId: transferId,
        byteCountOnServer: committed.byteCount,
        status: committed.status,
      );
    } finally {
      await raf.close();
    }
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

/// Phases the send progresses through (ADR-0004). The service-to-UI
/// progress callback fires with the current phase so the screen can
/// label it and reset the bar between phase transitions.
enum SendPhase {
  /// Streaming the plaintext through secretstream into a temp
  /// ciphertext file. `done` = plaintext bytes read; `total` = the
  /// declared plaintext length.
  encrypting,

  /// Post-encrypt, pre-upload gap: building `enc_header`, sealing
  /// K_file, signing, and POSTing `/initiate` (which presigns one
  /// URL per multipart part — non-trivial round-trip for a
  /// multi-GB file with ~700 parts). Progress is indeterminate;
  /// `done` and `total` are both 0.
  preparing,

  /// PUTting the temp ciphertext file to object storage — one part
  /// at a time on the multipart branch, or one PUT on single-shot.
  /// `done` = ciphertext bytes uploaded; `total` = final ciphertext
  /// size.
  uploading,
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
