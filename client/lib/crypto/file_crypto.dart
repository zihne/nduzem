import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as dart_crypto;
import 'package:sodium_libs/sodium_libs.dart';

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

  /// Stream-encrypt `plaintextPath` into a fresh temp file, computing
  /// `blob_sha256` incrementally as ciphertext chunks are produced
  /// (ADR-0004).
  ///
  /// Peak memory: ~one 64 KiB secretstream chunk + stream I/O
  /// overhead. Zero copies of the plaintext or the ciphertext held
  /// whole. Callers upload the resulting temp file part-by-part via
  /// [File.open]+[RandomAccessFile.read], keeping upload memory
  /// bounded to `part_size`.
  ///
  /// The temp file lives in `tempDir` (or `Directory.systemTemp` when
  /// none is provided — production wiring passes
  /// `path_provider.getTemporaryDirectory()`). The caller is
  /// responsible for deleting it after the send completes / aborts.
  ///
  /// `onProgress` fires per plaintext-read chunk with
  /// `(plaintextBytesRead, totalPlaintextBytes)`. `cancel` is checked
  /// per read chunk; on trip the stream terminates, the partial temp
  /// file is deleted, and `SendCancelledException`-shaped state
  /// propagates via the underlying stream error.
  Future<EncryptedFileResult> encryptFileToTempFile({
    required String plaintextPath,
    required Uint8List key,
    Directory? tempDir,
    void Function(int done, int total)? onProgress,
    void Function()? throwIfCancelled,
  }) async {
    final tmpDir = tempDir ?? Directory.systemTemp;
    if (!await tmpDir.exists()) {
      await tmpDir.create(recursive: true);
    }
    final source = File(plaintextPath);
    final totalBytes = await source.length();
    final tempFile = File(
      '${tmpDir.path}/opaqueshare-${_randomId()}.enc.tmp',
    );

    final secret = SecureKey.fromList(_sodium, key);
    dart_crypto.Digest? digest;
    final digestSink = ChunkedConversionSink<dart_crypto.Digest>.withCallback(
      (digests) => digest = digests.single,
    );
    final hasher = dart_crypto.sha256.startChunkedConversion(digestSink);
    final sink = tempFile.openWrite();

    var ciphertextLength = 0;
    try {
      sink.add(magicPrefix);
      hasher.add(magicPrefix);
      ciphertextLength += magicPrefix.length;

      // Throttle the progress callback: `File.openRead()` emits ~64 KiB
      // chunks by default, so on a multi-GB file we'd fire onProgress
      // several thousand times per second. That's not free — each call
      // marks the UI dirty. Emit at most every ~250 ms plus a
      // guaranteed final 100 % tick when the read completes.
      var plaintextRead = 0;
      var lastEmitAt = DateTime.now();
      const emitEvery = Duration(milliseconds: 250);
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
        sink.add(chunk);
        hasher.add(chunk);
        ciphertextLength += chunk.length;
      }

      await sink.flush();
      await sink.close();
      hasher.close();

      final finalDigest = digest;
      if (finalDigest == null) {
        // Defensive — the chunked conversion should always emit
        // exactly one digest on close.
        throw StateError('sha256 sink closed without emitting a digest');
      }
      return EncryptedFileResult(
        ciphertextPath: tempFile.path,
        ciphertextLength: ciphertextLength,
        blobSha256Hex: finalDigest.toString(),
      );
    } on Object {
      // Best-effort teardown: close any half-open sink, delete the
      // partial temp file. Rethrow the original error so the caller
      // sees the real cause (cancel, disk full, sodium failure, …).
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

  static String _randomId() {
    final rng = Random.secure();
    final buf = StringBuffer();
    for (var i = 0; i < 8; i++) {
      buf.write(rng.nextInt(1 << 30).toRadixString(36));
    }
    return buf.toString();
  }
}

/// Result of [FileCrypto.encryptFileToTempFile]. The caller uploads
/// `ciphertextPath` in `part_size` chunks (or single-shot for small
/// files) and MUST delete the file when done — success or failure.
class EncryptedFileResult {
  const EncryptedFileResult({
    required this.ciphertextPath,
    required this.ciphertextLength,
    required this.blobSha256Hex,
  });
  final String ciphertextPath;
  final int ciphertextLength;
  final String blobSha256Hex;
}
