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
  Future<Uint8List> encryptFile({
    required Uint8List plaintext,
    required Uint8List key,
  }) async {
    final secret = SecureKey.fromList(_sodium, key);
    try {
      // Emit the plaintext as a stream of (chunkSize + finalPushTag)
      // messages so `pushChunked` yields one ciphertext chunk per
      // input chunk plus the header as the very first emit.
      final input = _plainStream(plaintext);
      final output = _sodium.crypto.secretStream.pushChunked(
        messageStream: input,
        key: secret,
        chunkSize: plaintextChunkBytes,
      );
      final out = BytesBuilder(copy: false)..add(magicPrefix);
      await for (final chunk in output) {
        out.add(chunk);
      }
      return out.toBytes();
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
}
