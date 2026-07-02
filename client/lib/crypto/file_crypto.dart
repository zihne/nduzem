import 'dart:typed_data';

import 'package:crypto/crypto.dart' as dart_crypto;
import 'package:sodium_libs/sodium_libs.dart';

/// Symmetric file-body encryption for M2 single-PUT transfers.
///
/// Layout of the ciphertext blob (what gets PUT to R2):
///   `nonce (24 bytes) || crypto_secretbox_easy(plaintext, nonce, K_file)`
///
/// The 24-byte XSalsa20 nonce is generated fresh per transfer via
/// libsodium's CSPRNG (`randombytes_buf`), so K_file may be reused for
/// the header vs. body encryption without breaking security — nonces are
/// independent draws.
///
/// M4 will replace this with `crypto_secretstream_xchacha20poly1305` for
/// chunked multipart resumable uploads; the wire shape for M2 stays
/// simple deliberately.
class FileCrypto {
  const FileCrypto(this._sodium);
  final Sodium _sodium;

  /// 32 random bytes — the symmetric key for a single transfer.
  Uint8List generateFileKey() =>
      _sodium.randombytes.buf(_sodium.crypto.secretBox.keyBytes);

  /// Encrypt a small file (whole thing in memory — M2 is single-PUT).
  /// Returns the ciphertext blob suitable for direct upload to R2.
  Uint8List encryptFile({
    required Uint8List plaintext,
    required Uint8List key,
  }) {
    final nonce = _sodium.randombytes.buf(_sodium.crypto.secretBox.nonceBytes);
    final secret = SecureKey.fromList(_sodium, key);
    try {
      final ct = _sodium.crypto.secretBox.easy(
        message: plaintext,
        nonce: nonce,
        key: secret,
      );
      final blob = BytesBuilder(copy: false)
        ..add(nonce)
        ..add(ct);
      return blob.toBytes();
    } finally {
      secret.dispose();
    }
  }

  /// Decrypt a blob produced by [encryptFile]. Throws `SodiumException`
  /// on any integrity failure (Poly1305 tag mismatch, truncation, …).
  Uint8List decryptFile({
    required Uint8List ciphertextBlob,
    required Uint8List key,
  }) {
    final nonceLen = _sodium.crypto.secretBox.nonceBytes;
    if (ciphertextBlob.length < nonceLen) {
      throw ArgumentError('ciphertext too short to contain a nonce');
    }
    final nonce = ciphertextBlob.sublist(0, nonceLen);
    final ct = ciphertextBlob.sublist(nonceLen);
    final secret = SecureKey.fromList(_sodium, key);
    try {
      return _sodium.crypto.secretBox.openEasy(
        cipherText: ct,
        nonce: nonce,
        key: secret,
      );
    } finally {
      secret.dispose();
    }
  }

  /// SHA-256 hex of the ciphertext blob. Matches the server's
  /// `blob_sha256` expectation (a lowercase 64-char hex string).
  String sha256Hex(Uint8List bytes) =>
      dart_crypto.sha256.convert(bytes).toString();
}
