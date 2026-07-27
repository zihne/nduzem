import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as dart_crypto;
import 'package:sodium_libs/sodium_libs.dart';

import 'plaintext_source.dart';

/// Symmetric file-body encryption using chunked
/// `crypto_secretstream_xchacha20poly1305` (M4, ADR-0003).
///
/// Ciphertext layout (what gets uploaded to object storage):
///
/// ```
/// [4-byte magic "OS4S"]
/// [24-byte secretstream header]
/// [chunk_1_ct (plainSize + 17)]
/// [chunk_2_ct (plainSize + 17)]
/// ...
/// [chunk_N_ct (up to plainSize + 17, tag = FINAL)]
/// ```
///
/// - **Magic prefix**: self-identifying so a receiver on an older
///   client format-fails cleanly ("wrong magic") instead of failing
///   with a mysterious Poly1305 error.
/// - **Chunk size**: 64 KiB of plaintext per chunk. Small enough that
///   memory + CPU per chunk stay negligible; large enough that the
///   17-byte AEAD overhead is ~0.026% of the file size.
/// - **Last chunk**: carries `SecretStreamMessageTag.finalPush`.
///   Receiver hard-fails if the last chunk isn't finalized (truncation
///   defence).
///
/// Send-side memory model in this release: still buffers plaintext and
/// ciphertext whole. Streaming-from-disk is a follow-up (ADR-0003
/// "Not in this branch"); the on-the-wire format is streaming-ready
/// so that follow-up doesn't rev the format again.
class FileCrypto {
  const FileCrypto(this._sodium);
  final Sodium _sodium;

  /// Magic prefix identifying the M4 OS4S ciphertext container.
  static const List<int> magicPrefix = [0x4F, 0x53, 0x34, 0x53]; // 'OS4S'

  /// Plaintext bytes per secretstream chunk. Keep this constant —
  /// changing it here is a wire-format break for any in-flight
  /// transfers.
  static const int plaintextChunkBytes = 64 * 1024; // 64 KiB

  /// 32 random bytes — the symmetric key for a single transfer.
  Uint8List generateFileKey() => _sodium.crypto.secretStream.keygen().extractBytes();

  /// Ciphertext bytes per full secretstream chunk (plaintext + AEAD
  /// overhead). Exposed for tests + the receive path's chunk stepper.
  int get ciphertextChunkBytes =>
      plaintextChunkBytes + _sodium.crypto.secretStream.aBytes;

  /// Deterministic ciphertext length for a plaintext of `plaintextLen`
  /// bytes, matching what [encryptToStream] will emit for the same
  /// input (ADR-0014).
  ///
  /// Needed at `/initiate` time so the server can size the multipart
  /// plan (part count, per-part URLs) BEFORE the client has actually
  /// encrypted anything — the real ciphertext hash + length are only
  /// known once the streaming encryption pipeline drains. Server
  /// re-measures the object at `/commit` and rejects on mismatch, so
  /// an incorrect estimate is caught then, not silently.
  ///
  /// Formula: `magicPrefix(4) + secretstream_header(24) + plaintextLen
  /// + chunkCount * aBytes(17)`, where `chunkCount` matches
  /// [`_plainStream`]'s emission pattern: one empty final chunk for
  /// empty plaintext, otherwise `ceil(plaintextLen / plaintextChunkBytes)`.
  int estimateCiphertextLength(int plaintextLen) {
    final aBytes = _sodium.crypto.secretStream.aBytes;
    final headerBytes = _sodium.crypto.secretStream.headerBytes;
    final chunkCount = plaintextLen == 0
        ? 1
        : (plaintextLen + plaintextChunkBytes - 1) ~/ plaintextChunkBytes;
    return magicPrefix.length + headerBytes + plaintextLen + chunkCount * aBytes;
  }

  /// Encrypt `plaintext` into the OS4S container. The whole plaintext
  /// and the resulting ciphertext are held in memory — see the class
  /// docstring for the memory-model caveat.
  ///
  /// The output buffer is pre-sized to the known upper bound (header +
  /// plaintext + one AEAD tag per chunk + a small slack) so we make
  /// exactly one allocation for the ciphertext instead of a
  /// `BytesBuilder` that doubles its buffer as it grows. On a 70 MiB
  /// plaintext the difference is ~60 MiB of peak RSS — enough to
  /// keep Android's OOM killer out of the loop on mid-range devices.
  Future<Uint8List> encryptFile({
    required Uint8List plaintext,
    required Uint8List key,
  }) async {
    final secret = SecureKey.fromList(_sodium, key);
    try {
      final headerLen = _sodium.crypto.secretStream.headerBytes;
      final aBytes = _sodium.crypto.secretStream.aBytes;
      // Upper bound: one full-size ciphertext chunk per plaintext
      // chunk plus one extra chunk of slack to cover the empty
      // final-tag chunk libsodium may emit when plaintext ends on
      // an exact chunk boundary. `Uint8List.sublistView` at the end
      // trims to actual bytes written.
      final chunkCount = plaintext.isEmpty
          ? 1
          : ((plaintext.length + plaintextChunkBytes - 1) ~/
              plaintextChunkBytes);
      final maxSize = magicPrefix.length +
          headerLen +
          plaintext.length +
          (chunkCount + 1) * aBytes;
      final buffer = Uint8List(maxSize);
      var offset = 0;
      buffer.setRange(offset, offset + magicPrefix.length, magicPrefix);
      offset += magicPrefix.length;

      final input = _plainStream(plaintext);
      final output = _sodium.crypto.secretStream.pushChunked(
        messageStream: input,
        key: secret,
        chunkSize: plaintextChunkBytes,
      );
      await for (final chunk in output) {
        buffer.setRange(offset, offset + chunk.length, chunk);
        offset += chunk.length;
      }
      return Uint8List.sublistView(buffer, 0, offset);
    } finally {
      secret.dispose();
    }
  }

  Stream<List<int>> _plainStream(Uint8List plaintext) async* {
    var offset = 0;
    while (offset < plaintext.length) {
      final end = (offset + plaintextChunkBytes).clamp(0, plaintext.length);
      yield Uint8List.sublistView(plaintext, offset, end);
      offset = end;
    }
    // An empty plaintext still needs one chunk so `pushChunked` can
    // emit the FINAL-tagged message.
    if (plaintext.isEmpty) {
      yield Uint8List(0);
    }
  }

  /// Decrypt an OS4S container. Throws [FormatException] if the magic
  /// prefix is missing or wrong (likely an older-format ciphertext);
  /// throws `SodiumException` on any AEAD failure (byte corruption,
  /// truncation, wrong key).
  Future<Uint8List> decryptFile({
    required Uint8List ciphertextBlob,
    required Uint8List key,
  }) async {
    if (ciphertextBlob.length < magicPrefix.length) {
      throw const FormatException('ciphertext too short to contain the magic prefix');
    }
    for (var i = 0; i < magicPrefix.length; i++) {
      if (ciphertextBlob[i] != magicPrefix[i]) {
        throw const FormatException(
          'ciphertext missing OS4S magic — was this uploaded by an '
          'older client?',
        );
      }
    }
    final body = Uint8List.sublistView(ciphertextBlob, magicPrefix.length);
    final secret = SecureKey.fromList(_sodium, key);
    try {
      final chunks = _cipherStream(body);
      final output = _sodium.crypto.secretStream.pullChunked(
        cipherStream: chunks,
        key: secret,
        chunkSize: plaintextChunkBytes,
      );
      final out = BytesBuilder(copy: false);
      await for (final chunk in output) {
        out.add(chunk);
      }
      return out.toBytes();
    } finally {
      secret.dispose();
    }
  }

  /// Emit the ciphertext body as the secretstream's input expects it:
  /// header first, then successive ciphertext chunks of `aBytes`+
  /// plaintextChunkBytes each. The final chunk may be shorter — its
  /// `finalPush` tag is what signals stream end to the AEAD.
  Stream<List<int>> _cipherStream(Uint8List body) async* {
    final headerLen = _sodium.crypto.secretStream.headerBytes;
    if (body.length < headerLen) {
      throw const FormatException(
        'ciphertext too short to contain a secretstream header',
      );
    }
    yield Uint8List.sublistView(body, 0, headerLen);
    var offset = headerLen;
    final chunkLen = ciphertextChunkBytes;
    while (offset < body.length) {
      final end = (offset + chunkLen).clamp(0, body.length);
      yield Uint8List.sublistView(body, offset, end);
      offset = end;
    }
  }

  /// SHA-256 hex of the ciphertext blob. Matches the server's
  /// `blob_sha256` expectation (a lowercase 64-char hex string).
  String sha256Hex(Uint8List bytes) =>
      dart_crypto.sha256.convert(bytes).toString();

  /// Stream-encrypt `source` and return the ciphertext AS A STREAM
  /// of `Uint8List` chunks — no temp file (ADR-0013 Phase 2).
  ///
  /// This is the single send-path encryption API on all platforms.
  /// The output is a valid OS4S container using the same 64 KiB
  /// secretstream chunking as the receive side.
  ///
  ///   - **Output shape**: chunks emitted on a `Stream<Uint8List>`.
  ///   - **Summary delivery**: `blobSha256Hex` + `ciphertextLength`
  ///     are only known after the stream drains, so they're
  ///     delivered via the [EncryptStreamHandle.done] Future which
  ///     completes when the last chunk has been emitted.
  ///
  /// **Byte-equivalence is impossible by design.** libsodium's
  /// `crypto_secretstream_xchacha20poly1305_init_push` chooses a
  /// random header on every call — encrypting the same plaintext
  /// twice yields different ciphertext (that's the point of the
  /// random header). What IS invariant:
  ///
  ///   - Decrypting the emitted stream reproduces the original
  ///     plaintext bit-for-bit.
  ///   - `ciphertextLength` equals `plaintextLength + magic_prefix
  ///     + (chunk_count * secretstream_overhead)` — deterministic
  ///     given the input length.
  ///   - `blobSha256Hex` matches sha256 of the concatenated stream
  ///     chunks (rolling digest computed as chunks emit).
  ///
  /// **Caller contract** — you MUST fully consume the returned
  /// stream. The `done` Future only completes when the stream drains
  /// (normally or with an error). Cancelling the stream mid-way (by
  /// dropping the subscription) leaves `done` pending indefinitely.
  /// If you need mid-stream cancellation, throw from
  /// `throwIfCancelled`; that surfaces as an error on the stream AND
  /// completes `done` with the error.
  ///
  /// Peak memory: ~one 64 KiB secretstream chunk + the small rolling
  /// SHA-256 state. Zero copies of the plaintext or ciphertext held
  /// whole; the caller is expected to drain each chunk (upload it,
  /// accumulate into a part buffer, etc.) as it arrives.
  EncryptStreamHandle encryptToStream({
    required PlaintextSource source,
    required Uint8List key,
    void Function(int done, int total)? onProgress,
    void Function()? throwIfCancelled,
  }) {
    final doneCompleter = Completer<EncryptSummary>();
    final chunks = _encryptChunks(
      source: source,
      key: key,
      onProgress: onProgress,
      throwIfCancelled: throwIfCancelled,
      doneCompleter: doneCompleter,
    );
    return EncryptStreamHandle._(stream: chunks, done: doneCompleter.future);
  }

  Stream<Uint8List> _encryptChunks({
    required PlaintextSource source,
    required Uint8List key,
    required Completer<EncryptSummary> doneCompleter,
    void Function(int done, int total)? onProgress,
    void Function()? throwIfCancelled,
  }) async* {
    final totalBytes = source.lengthBytes;
    final secret = SecureKey.fromList(_sodium, key);

    dart_crypto.Digest? digest;
    final digestSink = ChunkedConversionSink<dart_crypto.Digest>.withCallback(
      (digests) => digest = digests.single,
    );
    final hasher = dart_crypto.sha256.startChunkedConversion(digestSink);
    var ciphertextLength = 0;

    // Progress throttle — see the docstring above for rationale.
    var plaintextRead = 0;
    var lastEmitAt = DateTime.now();
    const emitEvery = Duration(milliseconds: 250);

    try {
      final magic = Uint8List.fromList(magicPrefix);
      yield magic;
      hasher.add(magic);
      ciphertextLength += magic.length;

      final plaintextStream = source.openRead().map<List<int>>((chunk) {
        throwIfCancelled?.call();
        plaintextRead += chunk.length;
        final now = DateTime.now();
        final done = plaintextRead == totalBytes;
        if (done || now.difference(lastEmitAt) >= emitEvery) {
          lastEmitAt = now;
          onProgress?.call(plaintextRead, totalBytes);
        }
        return chunk;
      });

      final ciphertextStream = _sodium.crypto.secretStream.pushChunked(
        messageStream: plaintextStream,
        key: secret,
        chunkSize: plaintextChunkBytes,
      );

      await for (final chunk in ciphertextStream) {
        final asBytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
        yield asBytes;
        hasher.add(asBytes);
        ciphertextLength += asBytes.length;
      }

      hasher.close();
      final finalDigest = digest;
      if (finalDigest == null) {
        throw StateError('sha256 sink closed without emitting a digest');
      }
      if (!doneCompleter.isCompleted) {
        doneCompleter.complete(
          EncryptSummary(
            blobSha256Hex: finalDigest.toString(),
            ciphertextLength: ciphertextLength,
          ),
        );
      }
    } on Object catch (exc, st) {
      if (!doneCompleter.isCompleted) {
        doneCompleter.completeError(exc, st);
      }
      rethrow;
    } finally {
      secret.dispose();
    }
  }

  /// Stream-decrypt `ciphertextPath` into a fresh plaintext temp file
  /// (ADR-0006). Peak memory: ~one 64 KiB secretstream chunk + stream
  /// I/O overhead — no copies of the plaintext or ciphertext held whole.
  ///
  /// The caller is responsible for deleting the returned plaintext
  /// temp file after the recipient has saved or acked the transfer.
  ///
  /// Throws [FormatException] when the OS4S magic prefix is missing
  /// (older-format ciphertext) and `SodiumException` on any AEAD
  /// failure (byte corruption, truncation, wrong key). Reports
  /// progress per-chunk via `onProgress(plaintextBytesWritten,
  /// ciphertextBytesTotal)`. Cancellation via `throwIfCancelled` fires
  /// per read chunk; on trip the partial plaintext file is deleted.
  Future<DecryptedFileResult> decryptFileToTempFile({
    required String ciphertextPath,
    required Uint8List key,
    Directory? tempDir,
    void Function(int done, int total)? onProgress,
    void Function()? throwIfCancelled,
  }) async {
    final tmpDir = tempDir ?? Directory.systemTemp;
    if (!await tmpDir.exists()) {
      await tmpDir.create(recursive: true);
    }
    final source = File(ciphertextPath);
    final ctTotalBytes = await source.length();
    final tempFile = File(
      '${tmpDir.path}/opaqueshare-${_randomId()}.dec.tmp',
    );

    final secret = SecureKey.fromList(_sodium, key);
    final sink = tempFile.openWrite();
    var plaintextLength = 0;

    try {
      // Emit the ciphertext body (skipping the magic prefix) as a
      // stream: header first (24 bytes), then successive ciphertext
      // chunks of up to `aBytes + plaintextChunkBytes` each. Chunks
      // may straddle read-from-disk boundaries — we re-frame here.
      final ciphertextStream = _rechunkForPull(
        source,
        onProgress: onProgress,
        totalBytes: ctTotalBytes,
        throwIfCancelled: throwIfCancelled,
      );

      final plaintextStream = _sodium.crypto.secretStream.pullChunked(
        cipherStream: ciphertextStream,
        key: secret,
        chunkSize: plaintextChunkBytes,
      );

      await for (final chunk in plaintextStream) {
        sink.add(chunk);
        plaintextLength += chunk.length;
      }

      await sink.flush();
      await sink.close();

      return DecryptedFileResult(
        plaintextPath: tempFile.path,
        plaintextLength: plaintextLength,
      );
    } on Object {
      try {
        await sink.close();
      } on Object {
        // ignore
      }
      try {
        if (await tempFile.exists()) {
          await tempFile.delete();
        }
      } on Object {
        // ignore
      }
      rethrow;
    } finally {
      secret.dispose();
    }
  }

  /// Read the ciphertext file and yield: (1) the OS4S magic prefix is
  /// consumed and validated (not yielded — sodium doesn't want it);
  /// (2) the secretstream header as the first stream event; (3)
  /// successive ciphertext chunks of `ciphertextChunkBytes` bytes,
  /// with the last chunk possibly smaller. Progress + cancel fire per
  /// read chunk.
  Stream<List<int>> _rechunkForPull(
    File source, {
    void Function(int done, int total)? onProgress,
    required int totalBytes,
    void Function()? throwIfCancelled,
  }) async* {
    final headerLen = _sodium.crypto.secretStream.headerBytes;
    final magicLen = magicPrefix.length;
    final targetChunkLen = ciphertextChunkBytes;

    // A small buffer accumulates read chunks (which can be any size
    // depending on the underlying I/O) until we can hand out
    // (a) the magic prefix + header for validation and (b)
    // targetChunkLen-sized ciphertext chunks matching the encrypt
    // side's framing.
    final buffer = BytesBuilder(copy: false);
    var consumed = 0;
    var magicChecked = false;
    var headerEmitted = false;

    // Yields buffered bytes as sized chunks. Emits the header first
    // (if not yet emitted), then targetChunkLen-sized chunks. When
    // `flushAll` is true, emits whatever's left as the final chunk.
    Stream<List<int>> flush(bool flushAll) async* {
      if (!magicChecked && buffer.length >= magicLen) {
        final bytes = buffer.toBytes();
        for (var i = 0; i < magicLen; i++) {
          if (bytes[i] != magicPrefix[i]) {
            throw const FormatException(
              'ciphertext missing OS4S magic — was this uploaded by an '
              'older client?',
            );
          }
        }
        buffer.clear();
        buffer.add(bytes.sublist(magicLen));
        magicChecked = true;
      }
      if (!headerEmitted && buffer.length >= headerLen) {
        final bytes = buffer.toBytes();
        yield Uint8List.sublistView(bytes, 0, headerLen);
        buffer.clear();
        buffer.add(bytes.sublist(headerLen));
        headerEmitted = true;
      }
      while (headerEmitted && buffer.length >= targetChunkLen) {
        final bytes = buffer.toBytes();
        yield Uint8List.sublistView(bytes, 0, targetChunkLen);
        buffer.clear();
        buffer.add(bytes.sublist(targetChunkLen));
      }
      if (flushAll && buffer.length > 0) {
        yield buffer.toBytes();
        buffer.clear();
      }
    }

    await for (final chunk in source.openRead()) {
      throwIfCancelled?.call();
      buffer.add(chunk);
      consumed += chunk.length;
      onProgress?.call(consumed, totalBytes);
      yield* flush(false);
    }
    // Not enough bytes to even contain the magic + header → format
    // error surfaced later by sodium; but we might have consumed
    // fewer bytes than expected here without triggering a check.
    // The stream close below signals end-of-stream to pullChunked.
    yield* flush(true);
  }

  static String _randomId() => randomTempSlug();

  /// Short, collision-resistant slug for temp-file names. Reused by
  /// callers that build their own temp paths (e.g.
  /// `TransferService.receive` for the intermediate ciphertext temp).
  static String randomTempSlug() {
    final rng = Random.secure();
    final buf = StringBuffer();
    for (var i = 0; i < 8; i++) {
      buf.write(rng.nextInt(1 << 30).toRadixString(36));
    }
    return buf.toString();
  }
}

/// Handle returned by [FileCrypto.encryptToStream] (ADR-0013 Phase 2).
/// Two parts:
///
///   - [stream] emits the ciphertext chunk-by-chunk. The caller MUST
///     fully consume it — subscribe, drain, close — or [done] will
///     never resolve.
///   - [done] resolves with the summary (`blob_sha256`, ciphertext
///     length) once the stream has drained normally, or with the
///     same error the stream errored with.
class EncryptStreamHandle {
  const EncryptStreamHandle._({required this.stream, required this.done});
  final Stream<Uint8List> stream;
  final Future<EncryptSummary> done;
}

/// The two pieces of metadata a caller needs after streaming
/// encryption completes — the ciphertext SHA-256 (goes into the
/// server's `/initiate` call) and the total byte count (goes into
/// the multipart plan's total-size + used for quota accounting).
///
/// Only available AFTER [EncryptStreamHandle.stream] drains — the
/// hash and length are both accumulated as chunks emit, so they're
/// undefined mid-stream.
class EncryptSummary {
  const EncryptSummary({
    required this.blobSha256Hex,
    required this.ciphertextLength,
  });
  final String blobSha256Hex;
  final int ciphertextLength;
}

/// Result of [FileCrypto.decryptFileToTempFile] (ADR-0006). The caller
/// owns `plaintextPath` and MUST delete the file after the user has
/// saved / opened / acked it — success, cancel, or error.
class DecryptedFileResult {
  const DecryptedFileResult({
    required this.plaintextPath,
    required this.plaintextLength,
  });
  final String plaintextPath;
  final int plaintextLength;
}
