import 'dart:convert';
import 'dart:typed_data';

import 'package:sodium_libs/sodium_libs.dart';

/// Envelope-level primitives for the M2 send/receive path.
///
/// **`enc_header`** — a small AEAD-encrypted JSON blob describing the
/// plaintext file. Same layout as [FileCrypto]:
///     `nonce (24 bytes) || crypto_secretbox_easy(header_json, nonce, K_file)`
/// Only someone holding K_file can decrypt it. That's the recipient
/// (via `wrapped_key`) — the server sees an opaque blob and stores it
/// as-is.
///
/// The header fields the receiver expects:
///   - filename          (string, best-effort — sanitised for display)
///   - mime              (string or null)
///   - plaintext_length  (int, so the recipient can pre-allocate)
///   - blob_sha256       (redundant with the request, but lets the
///                        recipient re-verify locally without trusting
///                        the download response)
///
/// **`signature`** — Ed25519 detached signature over the raw bytes of
/// `blob_sha256` (the hex string is decoded to bytes). Verifiable by
/// anyone who knows the sender's `signing_pub`. Used for anti-
/// repudiation + man-in-the-middle detection.
class Envelope {
  const Envelope(this._sodium);
  final Sodium _sodium;

  /// Build the `enc_header` blob for a fresh transfer.
  Uint8List buildEncHeader({
    required String filename,
    required String? mime,
    required int plaintextLength,
    required String blobSha256Hex,
    required Uint8List fileKey,
  }) {
    final payload = <String, dynamic>{
      'filename': filename,
      'mime': mime,
      'plaintext_length': plaintextLength,
      'blob_sha256': blobSha256Hex,
    };
    final json = utf8.encode(jsonEncode(payload));
    final nonce = _sodium.randombytes.buf(_sodium.crypto.secretBox.nonceBytes);
    final secret = SecureKey.fromList(_sodium, fileKey);
    try {
      final ct = _sodium.crypto.secretBox.easy(
        message: Uint8List.fromList(json),
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

  /// Decode a downloaded `enc_header` blob. Throws `SodiumException` on
  /// integrity failure; throws [FormatException] on malformed JSON.
  DecryptedHeader openEncHeader({
    required Uint8List encHeader,
    required Uint8List fileKey,
  }) {
    final nonceLen = _sodium.crypto.secretBox.nonceBytes;
    if (encHeader.length < nonceLen) {
      throw ArgumentError('enc_header too short to contain a nonce');
    }
    final nonce = encHeader.sublist(0, nonceLen);
    final ct = encHeader.sublist(nonceLen);
    final secret = SecureKey.fromList(_sodium, fileKey);
    try {
      final json = _sodium.crypto.secretBox.openEasy(
        cipherText: ct,
        nonce: nonce,
        key: secret,
      );
      final map = jsonDecode(utf8.decode(json)) as Map<String, dynamic>;
      return DecryptedHeader(
        filename: map['filename'] as String? ?? '',
        mime: map['mime'] as String?,
        plaintextLength: (map['plaintext_length'] as num).toInt(),
        blobSha256Hex: map['blob_sha256'] as String? ?? '',
      );
    } finally {
      secret.dispose();
    }
  }

  /// Ed25519 detached signature over the raw bytes of `blob_sha256`.
  Uint8List signBlobSha256({
    required String blobSha256Hex,
    required Uint8List signingPrivate,
  }) {
    final message = _hexDecode(blobSha256Hex);
    final secret = SecureKey.fromList(_sodium, signingPrivate);
    try {
      return _sodium.crypto.sign.detached(message: message, secretKey: secret);
    } finally {
      secret.dispose();
    }
  }

  /// Verify a signature against the sender's `signing_pub`. Returns
  /// `true` on success, `false` on any authentication failure.
  bool verifyBlobSha256Signature({
    required String blobSha256Hex,
    required Uint8List signature,
    required Uint8List senderSigningPublic,
  }) {
    final message = _hexDecode(blobSha256Hex);
    try {
      return _sodium.crypto.sign.verifyDetached(
        signature: signature,
        message: message,
        publicKey: senderSigningPublic,
      );
    } on SodiumException {
      return false;
    }
  }

  Uint8List _hexDecode(String hex) {
    if (hex.length.isOdd) throw FormatException('odd-length hex: $hex');
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}

class DecryptedHeader {
  const DecryptedHeader({
    required this.filename,
    required this.mime,
    required this.plaintextLength,
    required this.blobSha256Hex,
  });
  final String filename;
  final String? mime;
  final int plaintextLength;
  final String blobSha256Hex;
}
