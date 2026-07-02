import 'dart:typed_data';

import 'package:sodium_libs/sodium_libs.dart';

/// Wraps `crypto_box_seal` / `crypto_box_seal_open` (spec §2.3).
///
/// **Send path** (sender wraps `K_file` for one recipient):
///   1. Take the recipient's `identity_pub` (X25519 public key).
///   2. `seal(K_file, recipientIdentityPub)` returns an anonymously
///      encrypted blob only the recipient can open. The sender's
///      identity does not appear in the ciphertext — anti-repudiation
///      comes from the separate signing key + envelope signature.
///
/// **Receive path** (recipient unwraps):
///   1. `sealOpen(sealed, recipientIdentityPub, recipientIdentityPriv)`
///      returns `K_file` verbatim.
///
/// libsodium's sealed box uses an ephemeral sender keypair internally
/// so we do not need to allocate or manage one.
class SealedBox {
  const SealedBox(this._sodium);
  final Sodium _sodium;

  /// Seal a small secret (typically K_file, 32 bytes) for a recipient.
  /// Returns the sealed ciphertext, ready for base64-encoding onto the
  /// `wrapped_key` field of the initiate request.
  Uint8List seal({
    required Uint8List message,
    required Uint8List recipientIdentityPublic,
  }) {
    return _sodium.crypto.box.seal(
      message: message,
      publicKey: recipientIdentityPublic,
    );
  }

  /// Unseal — the recipient calls this on the `wrapped_key` blob at
  /// download time to recover K_file. Throws `SodiumException` on any
  /// integrity / auth failure.
  Uint8List sealOpen({
    required Uint8List ciphertext,
    required Uint8List recipientIdentityPublic,
    required Uint8List recipientIdentityPrivate,
  }) {
    final secret = SecureKey.fromList(_sodium, recipientIdentityPrivate);
    try {
      return _sodium.crypto.box.sealOpen(
        cipherText: ciphertext,
        publicKey: recipientIdentityPublic,
        secretKey: secret,
      );
    } finally {
      secret.dispose();
    }
  }
}
