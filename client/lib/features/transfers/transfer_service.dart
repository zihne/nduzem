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
import '../../crypto/plaintext_source.dart';
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

  /// Encrypt, upload, and commit a transfer using the streaming
  /// pipeline (ADR-0013 + ADR-0014).
  ///
  /// Ciphertext is produced chunk-by-chunk from `source` via
  /// [FileCrypto.encryptToStream] and interleaved with the object-
  /// storage PUT: each 5 MiB accumulated buffer becomes a multipart
  /// part (or the whole ciphertext becomes one PUT under the
  /// threshold). No temp file. Peak memory ≈ `part_size` (~5 MiB)
  /// regardless of file size.
  ///
  /// `source` (ADR-0013) is the platform-neutral input:
  /// [FilePlaintextSource] on mobile (backed by a file path);
  /// [BytesPlaintextSource] for in-memory payloads;
  /// `BlobPlaintextSource` on web. Filename, MIME, and total
  /// plaintext length all come off `source`.
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
  /// **Contract change (ADR-0014)**: `blob_sha256`, `enc_header`,
  /// `signature`, and (app-mode) `wrapped_key` are sent at `/commit`
  /// once the streaming encryption has drained. The client precomputes
  /// `byte_count` for `/initiate` via
  /// [FileCrypto.estimateCiphertextLength] so the server can size the
  /// multipart plan before we've encrypted anything.
  ///
  /// `onProgress` fires with `(phase, done, total)`:
  ///   - `SendPhase.encrypting`: `done` = plaintext bytes read,
  ///     `total` = `source.lengthBytes`.
  ///   - `SendPhase.uploading`: `done` = ciphertext bytes PUT,
  ///     `total` = precomputed ciphertext size.
  ///
  /// `cancel` is checked between plaintext-read chunks and between
  /// part PUTs. Cancels after `/initiate` POST `/abort` before
  /// propagating so R2's in-flight parts are cleaned up immediately.
  Future<SendResult> send({
    required SendMode mode,
    UserLookup? recipient,
    required PlaintextSource source,
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
    // off. Wrap in try/catch so a platform without wakelock support
    // (test host, headless CI, web) doesn't break the send.
    try {
      await WakelockPlus.enable();
    } on Object {
      // ignore
    }
    try {
      // 1. Fresh K_file for this transfer.
      final fileKey = _fileCrypto.generateFileKey();

      // 2. Precompute the ciphertext byte_count so /initiate can size
      // the multipart plan. Server re-measures at /commit and rejects
      // on mismatch, so an incorrect estimate here fails loud, not
      // silent.
      final byteCount =
          _fileCrypto.estimateCiphertextLength(source.lengthBytes);

      // 3. Seal K_file for the recipient (crypto_box_seal) — app
      // mode only. Independent of ciphertext, so it can happen before
      // the stream starts.
      String? wrappedKeyB64;
      if (mode == SendMode.app) {
        final sealed = _sealedBox.seal(
          message: fileKey,
          recipientIdentityPublic: recipient!.identityPublic,
        );
        wrappedKeyB64 = base64Encode(sealed);
      }

      // 4. Read signing_priv up front so we don't discover a missing
      // key half-way through a multi-GB upload. ADR-0011: signing_priv
      // lives in a userId-scoped slot so a second account on this
      // device doesn't clobber it.
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

      // 5. Initiate — new contract (no crypto metadata; server ADR-0037).
      // Response is single-shot (upload_url) or multipart (parts plan).
      onProgress?.call(SendPhase.preparing, 0, 0);
      final initiated = await _transfers.initiate(
        mode: mode == SendMode.app ? 'app' : 'link',
        recipientId: recipient?.userId,
        linkPassword: linkPassword,
        recipientEmail: recipientEmail,
        byteCount: byteCount,
        maxDownloads: maxDownloads,
      );

      // 6. Stream-encrypt + upload interleaved. Anything from here
      // that throws MUST call /abort so R2 doesn't hold in-flight
      // parts open until the sweeper runs.
      try {
        onProgress?.call(SendPhase.uploading, 0, byteCount);
        final handle = _fileCrypto.encryptToStream(
          source: source,
          key: fileKey,
          throwIfCancelled: cancel?.throwIfCancelled,
          onProgress: (done, total) =>
              onProgress?.call(SendPhase.encrypting, done, total),
        );

        final List<CommitPart>? parts;
        if (initiated.multipart != null) {
          parts = await _streamToMultipart(
            handle: handle,
            plan: initiated.multipart!,
            byteCount: byteCount,
            onProgress: (up, total) =>
                onProgress?.call(SendPhase.uploading, up, total),
            cancel: cancel,
          );
        } else {
          parts = null;
          await _streamToSingleShot(
            handle: handle,
            uploadUrl: initiated.uploadUrl!,
            byteCount: byteCount,
            onProgress: (up, total) =>
                onProgress?.call(SendPhase.uploading, up, total),
            cancel: cancel,
          );
        }

        // 7. Await the summary — blob_sha256 + actual ciphertext
        // length. Only valid after the stream has fully drained,
        // which the upload loops above guarantee.
        final summary = await handle.done;

        // 8. Build enc_header + sign — both need blob_sha256.
        final encHeader = _envelope.buildEncHeader(
          filename: source.filename,
          mime: source.mimeType,
          plaintextLength: source.lengthBytes,
          blobSha256Hex: summary.blobSha256Hex,
          fileKey: fileKey,
        );
        final signature = _envelope.signBlobSha256(
          blobSha256Hex: summary.blobSha256Hex,
          signingPrivate: signingPriv,
        );

        // 9. Commit with crypto metadata + parts.
        final committed = await _transfers.commit(
          initiated.transferId,
          blobSha256Hex: summary.blobSha256Hex,
          encHeaderB64: base64Encode(encHeader),
          signatureB64: base64Encode(signature),
          wrappedKeyB64: wrappedKeyB64,
          parts: parts,
        );
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
        // orphan sweeper reclaim in the background.
        try {
          await _transfers.abort(initiated.transferId);
        } on Object {
          // ignore
        }
        rethrow;
      }
    } finally {
      try {
        await WakelockPlus.disable();
      } on Object {
        // ignore
      }
    }
  }

  /// Drain [handle.stream] into memory and PUT the whole ciphertext
  /// in one request. Only used when the server's `/initiate` response
  /// picked the single-shot branch (declared byte_count <= 5 MiB).
  Future<void> _streamToSingleShot({
    required EncryptStreamHandle handle,
    required String uploadUrl,
    required int byteCount,
    required void Function(int, int)? onProgress,
    required CancelToken? cancel,
  }) async {
    final buffer = BytesBuilder(copy: false);
    await for (final chunk in handle.stream) {
      cancel?.throwIfCancelled();
      buffer.add(chunk);
    }
    final body = buffer.takeBytes();
    final res = await runWithNetworkErrorTranslation(
      () => _httpClient.put(Uri.parse(uploadUrl), body: body),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw ApiException(
        statusCode: res.statusCode,
        message: 'Upload to storage failed (HTTP ${res.statusCode}).',
      );
    }
    onProgress?.call(body.length, byteCount);
  }

  /// Interleaved multipart uploader. Accumulates ciphertext chunks
  /// into a `plan.partSize`-byte buffer; PUTs each part as soon as
  /// it's full and captures the ETag; PUTs whatever remains as the
  /// final part when the stream drains.
  ///
  /// Peak memory ≈ `plan.partSize` (~5 MiB) + one 64 KiB stream chunk.
  /// Guards against a server plan mismatch by failing loudly if we
  /// run out of URLs before the stream drains — unused trailing URLs
  /// are silently dropped, which is safe (S3 `CompleteMultipartUpload`
  /// only cares about the parts we actually reference).
  Future<List<CommitPart>> _streamToMultipart({
    required EncryptStreamHandle handle,
    required MultipartUploadPlan plan,
    required int byteCount,
    required void Function(int, int)? onProgress,
    required CancelToken? cancel,
  }) async {
    final parts = <CommitPart>[];
    final urls = plan.parts;
    var urlIdx = 0;
    var uploaded = 0;
    final buffer = BytesBuilder(copy: false);

    Future<void> uploadOnePart(Uint8List body) async {
      cancel?.throwIfCancelled();
      if (urlIdx >= urls.length) {
        throw StateError(
          'Ran out of multipart part URLs — client-declared byte_count '
          'was smaller than the actual ciphertext size. Cannot commit.',
        );
      }
      final url = urls[urlIdx];
      final res = await runWithNetworkErrorTranslation(
        () => _httpClient.put(Uri.parse(url.url), body: body),
      );
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw ApiException(
          statusCode: res.statusCode,
          message: 'Upload of part ${url.partNumber} failed '
              '(HTTP ${res.statusCode}).',
        );
      }
      final etag = res.headers['etag'];
      if (etag == null || etag.isEmpty) {
        throw StateError(
          'Object storage did not return an ETag for part '
          '${url.partNumber}; cannot commit multipart upload.',
        );
      }
      parts.add(CommitPart(partNumber: url.partNumber, etag: etag));
      uploaded += body.length;
      onProgress?.call(uploaded, byteCount);
      urlIdx++;
    }

    await for (final chunk in handle.stream) {
      cancel?.throwIfCancelled();
      buffer.add(chunk);
      while (buffer.length >= plan.partSize) {
        // Slice one full part off the front of the buffer; the
        // remainder stays for the next iteration.
        final all = buffer.takeBytes();
        final partBody = Uint8List.sublistView(all, 0, plan.partSize);
        await uploadOnePart(Uint8List.fromList(partBody));
        if (all.length > plan.partSize) {
          buffer.add(Uint8List.sublistView(all, plan.partSize));
        }
      }
    }
    // Final partial part.
    if (buffer.length > 0) {
      await uploadOnePart(buffer.takeBytes());
    }
    return parts;
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

/// Phases the send progresses through (ADR-0013 + ADR-0014).
///
/// Under the streaming pipeline `encrypting` and `uploading` are
/// interleaved (chunks encrypt → accumulate → PUT → next chunks…),
/// so the UI should treat them as concurrent progress signals from
/// the same underlying operation rather than sequential stages. The
/// callback fires both event kinds during upload; pick whichever
/// makes the progress bar feel more responsive.
enum SendPhase {
  /// Plaintext bytes read from the source. `done` = plaintext bytes
  /// hashed + fed into secretstream; `total` = `source.lengthBytes`.
  encrypting,

  /// Pre-upload gap: sealing K_file, reading signing key, POSTing
  /// `/initiate` (which presigns one URL per multipart part —
  /// non-trivial for a multi-GB file with ~700 parts). Progress is
  /// indeterminate; `done` and `total` are both 0.
  preparing,

  /// Ciphertext bytes PUT to object storage. `done` = uploaded so
  /// far; `total` = precomputed ciphertext byte_count. Under the
  /// streaming pipeline this can overlap with `encrypting` because
  /// each part is uploaded as its chunks emerge.
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
