import 'dart:convert';
import 'dart:typed_data';

import 'package:sodium_libs/sodium_libs.dart';

/// Identity + signing keypair generation on device (spec §2.3 / §6).
///
/// Private keys NEVER leave the device — they land in
/// `flutter_secure_storage` (Keychain on iOS, EncryptedSharedPreferences on
/// Android). Only public keys travel to the backend.
///
/// suite=1 primitives:
///   - identity : X25519 (for crypto_box_seal K_file wrap in app mode)
///   - signing  : Ed25519 (envelope signature over blob_sha256)
class IdentityKeypair {
  const IdentityKeypair({
    required this.identityPublic,
    required this.identityPrivate,
    required this.signingPublic,
    required this.signingPrivate,
  });

  final Uint8List identityPublic;
  final Uint8List identityPrivate;
  final Uint8List signingPublic;
  final Uint8List signingPrivate;

  /// Base64 encoding of the public halves, exactly what the backend
  /// `/v1/auth/register` endpoint accepts. Private halves are NEVER
  /// serialised here — separate paths write them into secure storage.
  String get identityPublicB64 => base64Encode(identityPublic);
  String get signingPublicB64 => base64Encode(signingPublic);
}

/// Thin wrapper around `sodium_libs` so tests can inject a fake and so a
/// future PQC-suite dispatch (spec §2.6) has a single call site.
class KeypairGenerator {
  const KeypairGenerator(this._sodium);

  final Sodium _sodium;

  /// Generate a fresh (identity, signing) keypair pair. Runs on the current
  /// isolate; libsodium's CSPRNG does the work, so total wall-clock is
  /// microseconds.
  IdentityKeypair generate() {
    final identity = _sodium.crypto.box.keyPair();
    final signing = _sodium.crypto.sign.keyPair();
    try {
      return IdentityKeypair(
        identityPublic: identity.publicKey,
        identityPrivate: identity.secretKey.extractBytes(),
        signingPublic: signing.publicKey,
        signingPrivate: signing.secretKey.extractBytes(),
      );
    } finally {
      // `SecureKey` holds a mlock'd buffer that must be released even
      // though we've copied out the bytes — the copies live in the
      // `IdentityKeypair` and get handed to secure storage.
      identity.secretKey.dispose();
      signing.secretKey.dispose();
    }
  }
}
