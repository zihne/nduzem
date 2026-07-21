import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as dart_crypto;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../api/api_client.dart';
import '../../api/links_api.dart';
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
    required LinksApi links,
    required UsersApi users,
    required SealedBox sealedBox,
    required FileCrypto fileCrypto,
    required Envelope envelope,
    required SecureStore storage,
    http.Client? httpClient,
  })  : _transfers = transfers,
        _links = links,
        _users = users,
        _sealedBox = sealedBox,
        _fileCrypto = fileCrypto,
        _envelope = envelope,
        _storage = storage,
        _http = httpClient;

  final TransfersApi _transfers;
  final LinksApi _links;
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
  /// **Modes** (ADR-0005):
  ///   - [SendMode.app]: recipient has an account; K_file is sealed
  ///     to their `identity_pub` and travels through the server as
  ///     `wrapped_key`. Requires a non-null `recipient`.
  ///   - [SendMode.link]: recipient has no account. K_file is NOT
  ///     sealed and NOT sent to the server; it's returned to the
  ///     caller in [SendResult.linkFileKey] for the caller to embed
  ///     in the URL fragment (`<origin>/r/<id>#<K_file>`). Optional
  ///     `linkPassword` gates the download on the server side.
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
    required SendMode mode,
    UserLookup? recipient,
    required String plaintextPath,
    required int plaintextLength,
    required String filename,
    String? mime,
    String? linkPassword,
    String? recipientEmail,
    int maxDownloads = 1,
    void Function(SendPhase phase, int done, int total)? onProgress,
    CancelToken? cancel,
  }) async {
    assert(
      mode != SendMode.app || recipient != null,
      'SendMode.app requires a non-null recipient',
    );
    // Partial wakelock across the whole send. Multi-GB uploads run
    // for minutes; if the user pockets the phone the screen goes off
    // and Android's Doze can otherwise starve our upload of CPU /
    // network. Wakelock keeps the CPU awake even with the screen
    // off. It does NOT protect against the App Freezer if the user
    // switches to a different app — that's a foreground-service job
    // (deferred). Wrap in try/catch so a platform without wakelock
    // support (test host, headless CI) doesn't break the send.
    try {
      await WakelockPlus.enable();
    } on Object {
      // ignore — upload works fine without a wakelock, just less
      // resilient to screen-off scenarios.
    }
    try {
      // 1. Fresh K_file for this transfer.
      final fileKey = _fileCrypto.generateFileKey();

      // 2. Stream-encrypt plaintext → temp file, rolling SHA-256 in
      // the same pass. Peak memory ≈ one 64 KiB secretstream chunk.
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

      // 4. Seal K_file for the recipient (crypto_box_seal) — app
      // mode only. In link mode K_file rides in the URL fragment;
      // the server never sees it.
      String? wrappedKeyB64;
      if (mode == SendMode.app) {
        final sealed = _sealedBox.seal(
          message: fileKey,
          recipientIdentityPublic: recipient!.identityPublic,
        );
        wrappedKeyB64 = base64Encode(sealed);
      }

      // 5. Sign blob_sha256 with our Ed25519 signing_priv. Wire shape
      // is identical across modes; the web decrypt page ignores the
      // signature (ADR-0035) but a future authenticated-link feature
      // could verify it. ADR-0011: signing_priv lives in a userId-
      // scoped slot so a second account on this device doesn't clobber
      // it.
      final activeUserId = await _storage.read(SecureStore.kUserId);
      if (activeUserId == null) {
        throw StateError(
          'No signed-in user on this device. Sign in before sending.',
        );
      }
      final signingPriv = await _storage.readBytes(
        SecureStore.signingPrivateKeyFor(activeUserId),
      );
      if (signingPriv == null) {
        throw StateError(
          "This device doesn't have the signing key for this account. "
          'The account was likely created on another device, or an older '
          'app version overwrote the key when a second account was '
          'registered here. Register a fresh account on this device to '
          'send from here, or sign in from the device where this account '
          'was originally registered.',
        );
      }
      final signature = _envelope.signBlobSha256(
        blobSha256Hex: enc.blobSha256Hex,
        signingPrivate: signingPriv,
      );

      // 6. Initiate on the server. Response is either single-shot or
      // multipart shape — same envelope, different upload path.
      final initiated = await _transfers.initiate(
        mode: mode == SendMode.app ? 'app' : 'link',
        recipientId: recipient?.userId,
        wrappedKeyB64: wrappedKeyB64,
        linkPassword: linkPassword,
        recipientEmail: recipientEmail,
        byteCount: enc.ciphertextLength,
        blobSha256Hex: enc.blobSha256Hex,
        encHeaderB64: base64Encode(encHeader),
        signatureB64: base64Encode(signature),
        maxDownloads: maxDownloads,
      );

      // 7 + 8. Upload + commit. Anything from here that throws MUST
      // call /abort on the multipart branch so R2 doesn't hold
      // in-flight parts open until the server's 6-hour sweeper runs.
      onProgress?.call(SendPhase.uploading, 0, enc.ciphertextLength);
      try {
        final CommitTransferResponse committed;
        if (initiated.multipart != null) {
          committed = await _sendMultipartFromFile(
            transferId: initiated.transferId,
            ciphertextFile: ciphertextFile,
            ciphertextLength: enc.ciphertextLength,
            plan: initiated.multipart!,
            onProgress: (up, total) =>
                onProgress?.call(SendPhase.uploading, up, total),
            cancel: cancel,
          );
        } else {
          committed = await _sendSingleShotFromFile(
            transferId: initiated.transferId,
            ciphertextFile: ciphertextFile,
            ciphertextLength: enc.ciphertextLength,
            uploadUrl: initiated.uploadUrl!,
            onProgress: (up, total) =>
                onProgress?.call(SendPhase.uploading, up, total),
            cancel: cancel,
          );
        }
        return SendResult(
          mode: mode,
          transferId: initiated.transferId,
          byteCountOnServer: committed.byteCount,
          status: committed.status,
          // K_file is handed back to the caller ONLY in link mode so
          // the UI can embed it in the URL fragment. App mode never
          // needs it after this point — the sealed copy sits on the
          // server for the recipient to unseal.
          linkFileKey: mode == SendMode.link ? fileKey : null,
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
    } finally {
      // Release the wakelock regardless of outcome. Wrap in try/catch
      // so a platform without wakelock support doesn't turn a
      // successful send into a failure.
      try {
        await WakelockPlus.disable();
      } on Object {
        // ignore
      }
    }
  }

  Future<CommitTransferResponse> _sendSingleShotFromFile({
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
    final putRes = await runWithNetworkErrorTranslation(
      () => _httpClient.put(Uri.parse(uploadUrl), body: body),
    );
    if (putRes.statusCode < 200 || putRes.statusCode >= 300) {
      throw ApiException(
        statusCode: putRes.statusCode,
        message: 'Upload to storage failed (HTTP ${putRes.statusCode}).',
      );
    }
    onProgress?.call(ciphertextLength, ciphertextLength);

    cancel?.throwIfCancelled();
    return _transfers.commit(transferId);
  }

  Future<CommitTransferResponse> _sendMultipartFromFile({
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
        final res = await runWithNetworkErrorTranslation(
          () => _httpClient.put(Uri.parse(partUrl.url), body: body),
        );
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
      return _transfers.commit(transferId, parts: parts);
    } finally {
      await raf.close();
    }
  }

  // --- INBOX ------------------------------------------------------------

  Future<List<InboxItem>> inbox() => _transfers.inbox();

  // --- RECEIVE ----------------------------------------------------------

  /// Streaming receive (ADR-0006). Downloads the ciphertext into a
  /// temp file while rolling a SHA-256 hash on the fly, verifies the
  /// hash against the server-reported `blob_sha256`, verifies the
  /// sender signature, unseals K_file + `enc_header`, then
  /// streaming-decrypts to a second temp file. The caller (receive
  /// screen) owns the plaintext temp file: reads it into memory at
  /// save-time for `file_picker.saveFile`, then deletes it after ack.
  ///
  /// Peak memory during download + decrypt ≈ ~one 64 KiB chunk. The
  /// save-time buffer is the residual OOM risk on multi-GB files —
  /// slated for a follow-up branch that streams into a SAF URI.
  Future<DecryptedTransfer> receive({
    required String transferId,
    void Function(ReceivePhase phase, int done, int total)? onProgress,
    CancelToken? cancel,
  }) async {
    // Partial wakelock across the whole receive — mirror of the send
    // side. Multi-GB downloads can run for minutes; if the user pockets
    // the phone, Doze can otherwise starve the network read and stall
    // the streaming download. Wakelock keeps the CPU + network alive
    // with the screen off. Does NOT defend against the App Freezer
    // when the user switches to a different app — that's a foreground-
    // service concern for later. Wrapped in try/catch so a platform
    // without wakelock support (test host, headless CI) still works.
    try {
      await WakelockPlus.enable();
    } on Object {
      // ignore — download works fine without a wakelock, just less
      // resilient to screen-off scenarios.
    }
    try {
      // 1. Get presigned URL + envelope.
      final dl = await _transfers.requestDownload(transferId);
      if (dl.wrappedKeyB64 == null) {
        throw StateError(
          'This transfer is link-mode (wrapped_key is null). Link mode '
          'client-side receive is a separate follow-up.',
        );
      }

      final tempDir = await getTemporaryDirectory();
      final ciphertextFile = File(
        '${tempDir.path}/opaqueshare-${FileCrypto.randomTempSlug()}.ct.tmp',
      );

      try {
      // 2. Stream the ciphertext into a temp file, hashing as we go.
      // Rolling SHA-256 lets us verify integrity without a second
      // pass over the file. `Content-Length` from the storage layer
      // is the progress total; falls back to the envelope's declared
      // byte_count if the header is missing.
      final downloadedLength = await _streamDownloadWithHash(
        url: dl.downloadUrl,
        destination: ciphertextFile,
        expectedSha256Hex: dl.blobSha256Hex,
        onProgress: onProgress,
        cancel: cancel,
      );

      // 3. Verify the sender signature — same wire contract as the
      // in-memory path (ADR-0031). Skipped when the sender has erased
      // themselves and the server withheld their pubkey.
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
            "Sender's signature does not verify against their "
            'signing_pub — refusing to decrypt.',
          );
        }
        senderSignatureVerified = true;
      }

      // 4. Unseal wrapped_key with our identity keypair. ADR-0011: the
      // keypair lives in userId-scoped slots so this device can host
      // more than one account without stepping on itself.
      final activeUserId = await _storage.read(SecureStore.kUserId);
      if (activeUserId == null) {
        throw StateError(
          'No signed-in user on this device. Sign in before receiving.',
        );
      }
      final identityPriv = await _storage.readBytes(
        SecureStore.identityPrivateKeyFor(activeUserId),
      );
      final identityPub = await _storage.readBytes(
        SecureStore.identityPublicKeyFor(activeUserId),
      );
      if (identityPriv == null || identityPub == null) {
        throw StateError(
          "This device doesn't have the identity keypair for this "
          'account. The account was likely created on another device, or '
          'an older app version overwrote the keys when a second account '
          'was registered here. Sign in from the device where this '
          'account was originally registered to decrypt received '
          'transfers.',
        );
      }
      final fileKey = _sealedBox.sealOpen(
        ciphertext: base64Decode(dl.wrappedKeyB64!),
        recipientIdentityPublic: identityPub,
        recipientIdentityPrivate: identityPriv,
      );

      // 5. Decrypt enc_header (small, in-memory — unchanged from M2).
      final header = _envelope.openEncHeader(
        encHeader: base64Decode(dl.encHeaderB64),
        fileKey: fileKey,
      );

      // 6. Stream-decrypt the ciphertext temp file into a plaintext
      // temp file. Throws FormatException on missing OS4S magic and
      // SodiumException on any AEAD failure.
      cancel?.throwIfCancelled();
      onProgress?.call(ReceivePhase.decrypting, 0, downloadedLength);
      final dec = await _fileCrypto.decryptFileToTempFile(
        ciphertextPath: ciphertextFile.path,
        key: fileKey,
        tempDir: tempDir,
        throwIfCancelled: cancel?.throwIfCancelled,
        onProgress: (done, total) =>
            onProgress?.call(ReceivePhase.decrypting, done, total),
      );

      // Guardrail: what the header claimed the length would be MUST
      // match what we actually decrypted. Any mismatch is a
      // tampering signal.
      if (dec.plaintextLength != header.plaintextLength) {
        // Clean the plaintext temp we just wrote before we throw.
        try {
          await File(dec.plaintextPath).delete();
        } on Object {
          // ignore
        }
        throw StateError(
          'Decrypted plaintext length (${dec.plaintextLength}) does '
          'not match the header claim (${header.plaintextLength}).',
        );
      }

      return DecryptedTransfer(
        transferId: transferId,
        // Sanitise the filename so a malicious sender can't inject
        // path separators / suspicious names into the eventual save
        // dialog.
        filename: _sanitiseFilename(header.filename, transferId),
        mime: header.mime,
        plaintextPath: dec.plaintextPath,
        plaintextLength: dec.plaintextLength,
        senderSignatureVerified: senderSignatureVerified,
        senderIdentityPubB64: dl.senderIdentityPubB64,
        senderId: dl.senderId,
        senderHandle: dl.senderHandle,
      );
      } finally {
        // Always drop the ciphertext temp file. Success, cancel, or
        // failure — the ciphertext is consumed by the decrypt step.
        try {
          if (await ciphertextFile.exists()) {
            await ciphertextFile.delete();
          }
        } on Object {
          // ignore
        }
      }
    } finally {
      // Release the wakelock regardless of outcome. Wrap in try/catch
      // so a platform without wakelock support doesn't turn a
      // successful receive into a failure.
      try {
        await WakelockPlus.disable();
      } on Object {
        // ignore
      }
    }
  }

  /// Stream the presigned-URL response body into [destination] while
  /// feeding each read chunk into a chunked SHA-256 hasher. Returns
  /// the total bytes written and throws on a hash mismatch (before
  /// any further work is spent). Progress fires on
  /// `ReceivePhase.downloading` throttled to ~250 ms.
  Future<int> _streamDownloadWithHash({
    required String url,
    required File destination,
    required String expectedSha256Hex,
    required void Function(ReceivePhase, int, int)? onProgress,
    required CancelToken? cancel,
  }) async {
    final request = http.Request('GET', Uri.parse(url));
    final resp = await runWithNetworkErrorTranslation(
      () => _httpClient.send(request),
    );
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw ApiException(
        statusCode: resp.statusCode,
        message:
            'Download from storage failed (HTTP ${resp.statusCode}).',
      );
    }
    final totalBytes = resp.contentLength ?? 0;

    dart_crypto.Digest? capturedDigest;
    final digestSink =
        ChunkedConversionSink<dart_crypto.Digest>.withCallback(
      (digests) => capturedDigest = digests.single,
    );
    final hasher = dart_crypto.sha256.startChunkedConversion(digestSink);
    final sink = destination.openWrite();
    var received = 0;
    var lastEmitAt = DateTime.now();
    const emitEvery = Duration(milliseconds: 250);
    try {
      onProgress?.call(ReceivePhase.downloading, 0, totalBytes);
      // Wrap the stream iteration in the same translator — the socket
      // can drop mid-download and surface as ClientException or
      // SocketException from inside the async iterator.
      await runWithNetworkErrorTranslation(() async {
        await for (final chunk in resp.stream) {
          cancel?.throwIfCancelled();
          sink.add(chunk);
          hasher.add(chunk);
          received += chunk.length;
          final now = DateTime.now();
          if (now.difference(lastEmitAt) >= emitEvery) {
            lastEmitAt = now;
            onProgress?.call(
              ReceivePhase.downloading,
              received,
              totalBytes,
            );
          }
        }
      });
      // Final tick.
      onProgress?.call(ReceivePhase.downloading, received, totalBytes);
      await sink.flush();
      await sink.close();
      hasher.close();
    } on Object {
      try {
        await sink.close();
      } on Object {
        // ignore
      }
      rethrow;
    }

    final digest = capturedDigest;
    if (digest == null) {
      throw StateError('sha256 sink closed without emitting a digest');
    }
    if (digest.toString() != expectedSha256Hex) {
      throw StateError(
        'Downloaded ciphertext hash does not match the server-reported '
        'blob_sha256 — refusing to decrypt.',
      );
    }
    return received;
  }

  /// POST /ack — server enqueues the burn-after-read delete of the
  /// ciphertext object.
  Future<String> ack(String transferId) => _transfers.ack(transferId);

  // --- RECEIVE (link mode, ADR-0010) ------------------------------------

  /// Look up a link-mode transfer's public info. The [LinkReceiveScreen]
  /// calls this first to decide whether to show a password prompt, an
  /// "expired" panel, etc.
  Future<LinkInfo> linkInfo(String transferId) => _links.info(transferId);

  /// POST /v1/links/{id}/ack — link-mode counterpart to [ack]. Same
  /// idempotent semantics as the authed path.
  Future<String> linkAck(String transferId) => _links.ack(transferId);

  /// Link-mode streaming receive. Mirrors [receive] step-for-step
  /// except:
  ///
  ///  - Endpoint is `/v1/links/{id}/download` (no bearer token).
  ///  - K_file arrives from the URL fragment as [fileKey], not from
  ///    unsealing `wrapped_key`.
  ///  - No sender identity to verify against — signature verification
  ///    is skipped and [DecryptedTransfer.senderSignatureVerified] is
  ///    reported as `false`.
  ///
  /// [password] is forwarded to the server for password-protected
  /// links; ignored server-side when the link has no password. A
  /// wrong / missing password comes back as an [ApiException] with
  /// statusCode 401, which the screen surfaces as a retry-with-password
  /// prompt.
  Future<DecryptedTransfer> receiveLinkMode({
    required String transferId,
    required Uint8List fileKey,
    String? password,
    void Function(ReceivePhase phase, int done, int total)? onProgress,
    CancelToken? cancel,
  }) async {
    // Wakelock across the whole receive — same rationale as the
    // authed receive path.
    try {
      await WakelockPlus.enable();
    } on Object {
      // ignore
    }
    try {
      // 1. Presigned URL + envelope. This is also the point at which
      // the password gets checked and download_count increments.
      final dl = await _links.download(transferId, password: password);

      final tempDir = await getTemporaryDirectory();
      final ciphertextFile = File(
        '${tempDir.path}/opaqueshare-${FileCrypto.randomTempSlug()}.ct.tmp',
      );

      try {
        // 2. Stream ciphertext to temp file + rolling SHA-256.
        final downloadedLength = await _streamDownloadWithHash(
          url: dl.downloadUrl,
          destination: ciphertextFile,
          expectedSha256Hex: dl.blobSha256Hex,
          onProgress: onProgress,
          cancel: cancel,
        );

        // 3. Sender-signature verification is intentionally skipped:
        //    link mode has no on-platform sender identity, and the
        //    server withholds `sender_signing_pub` on this endpoint by
        //    design (ADR-0010). The screen renders "signature not
        //    verified" so users understand the semantics.

        // 4. Decrypt enc_header with the fragment-supplied file key.
        final header = _envelope.openEncHeader(
          encHeader: base64Decode(dl.encHeaderB64),
          fileKey: fileKey,
        );

        // 5. Stream-decrypt ciphertext → plaintext.
        cancel?.throwIfCancelled();
        onProgress?.call(ReceivePhase.decrypting, 0, downloadedLength);
        final dec = await _fileCrypto.decryptFileToTempFile(
          ciphertextPath: ciphertextFile.path,
          key: fileKey,
          tempDir: tempDir,
          throwIfCancelled: cancel?.throwIfCancelled,
          onProgress: (done, total) =>
              onProgress?.call(ReceivePhase.decrypting, done, total),
        );

        if (dec.plaintextLength != header.plaintextLength) {
          try {
            await File(dec.plaintextPath).delete();
          } on Object {
            // ignore
          }
          throw StateError(
            'Decrypted plaintext length (${dec.plaintextLength}) does '
            'not match the header claim (${header.plaintextLength}).',
          );
        }

        return DecryptedTransfer(
          transferId: transferId,
          filename: _sanitiseFilename(header.filename, transferId),
          mime: header.mime,
          plaintextPath: dec.plaintextPath,
          plaintextLength: dec.plaintextLength,
          // Link mode has no signature to verify against — the
          // JS decrypt page skips this same step (ADR-0010).
          senderSignatureVerified: false,
          senderIdentityPubB64: null,
          senderId: null,
          senderHandle: null,
        );
      } finally {
        try {
          if (await ciphertextFile.exists()) {
            await ciphertextFile.delete();
          }
        } on Object {
          // ignore
        }
      }
    } finally {
      try {
        await WakelockPlus.disable();
      } on Object {
        // ignore
      }
    }
  }

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

/// Which end-to-end path the send takes (ADR-0005).
enum SendMode {
  /// Recipient has an account. K_file is sealed to their
  /// `identity_pub` (crypto_box_seal), delivered by the server as
  /// `wrapped_key`. Requires a resolved [UserLookup].
  app,

  /// Recipient has no account. K_file is NOT sealed and NOT sent to
  /// the server; it's returned via [SendResult.linkFileKey] so the
  /// UI can embed it in the URL fragment (`<origin>/r/<id>#<K_file>`).
  /// Optional password on the server side gates the download.
  link,
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

/// Phases the receive progresses through (ADR-0006). Mirror of
/// [SendPhase] on the download side. Rate-limited to ~250 ms per
/// phase to keep the UI thread free during multi-GB transfers.
enum ReceivePhase {
  /// GETting the ciphertext into a temp file, streaming SHA-256 in
  /// the same pass. `done` = ciphertext bytes received; `total` =
  /// server-reported ciphertext length.
  downloading,

  /// Streaming the ciphertext temp file through secretstream into a
  /// plaintext temp file. `done` = plaintext bytes written; `total`
  /// = ciphertext bytes read (progress on the source stream).
  decrypting,
}

// --- domain result types -------------------------------------------------

class SendResult {
  const SendResult({
    required this.mode,
    required this.transferId,
    required this.byteCountOnServer,
    required this.status,
    this.linkFileKey,
  });

  /// Which send path produced this result.
  final SendMode mode;
  final String transferId;
  final int byteCountOnServer;
  final String status;

  /// Raw K_file bytes, populated ONLY when `mode == SendMode.link`.
  /// The caller base64url-encodes this into the URL fragment so the
  /// recipient can decrypt via the web page (ADR-0005). Null in app
  /// mode — K_file was sealed to the recipient's identity_pub and
  /// isn't needed by the sender after upload.
  final Uint8List? linkFileKey;
}

/// Result of a successful streaming download + decrypt (ADR-0006).
/// The plaintext lives at `plaintextPath` as a temp file — the caller
/// owns its lifetime: reads it into memory at save-time for
/// `file_picker.saveFile`, then deletes it after ack (or cancel).
class DecryptedTransfer {
  const DecryptedTransfer({
    required this.transferId,
    required this.filename,
    required this.mime,
    required this.plaintextPath,
    required this.plaintextLength,
    required this.senderSignatureVerified,
    required this.senderIdentityPubB64,
    required this.senderId,
    required this.senderHandle,
  });
  final String transferId;
  final String filename;
  final String? mime;

  /// Filesystem path of the decrypted plaintext, held as a temp file
  /// under the OS temp dir. The receive screen reads bytes from here
  /// only at save-time (peak memory = plaintext size, once), then
  /// deletes on ack.
  final String plaintextPath;
  final int plaintextLength;

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

  /// Sender's account id (UUID as string). Null in link mode and for
  /// erased senders. The receive screen persists the first 8 chars to
  /// on-device history (ADR-0007) as a compact fallback when
  /// [senderHandle] isn't set.
  final String? senderId;

  /// Sender's decrypted handle (per ADR-0031) if the server surfaced
  /// one. Null in link mode, for erased senders, and for senders that
  /// never set a handle. Persisted to on-device history so past
  /// receives show as `@alice` rather than a UUID prefix.
  final String? senderHandle;
}
