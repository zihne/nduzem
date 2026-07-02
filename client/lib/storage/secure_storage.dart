import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Hardware-backed secret storage (spec §12B.7).
///
/// - iOS   : Keychain with `first_unlock` accessibility
/// - Android: EncryptedSharedPreferences (AES-256 GCM)
///
/// The rule: nothing sensitive touches disk except through this facade.
/// Callers that need bytes go through `readBytes`; string callers go
/// through `read`. Keys are namespaced by prefix so a future purge can
/// scope by owner (e.g. account switch).
class SecureStore {
  SecureStore({FlutterSecureStorage? backend})
      : _backend = backend ??
            const FlutterSecureStorage(
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock,
              ),
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            );

  final FlutterSecureStorage _backend;

  // --- Well-known key names -----------------------------------------------
  // Suffixes here match on-disk keys; changing them is a data-migration event.

  static const String kIdentityPrivate = 'auth.identity_private_b64';
  static const String kIdentityPublic = 'auth.identity_public_b64';
  static const String kSigningPrivate = 'auth.signing_private_b64';
  static const String kSigningPublic = 'auth.signing_public_b64';
  static const String kAccessToken = 'auth.access_token';
  static const String kRefreshToken = 'auth.refresh_token';
  static const String kUserId = 'auth.user_id';
  static const String kEmail = 'auth.email';
  static const String kFingerprint = 'auth.fingerprint';
  static const String kMfaEnabled = 'auth.mfa_enabled';

  // --- string API ----------------------------------------------------------

  Future<void> write(String key, String value) =>
      _backend.write(key: key, value: value);

  Future<String?> read(String key) => _backend.read(key: key);

  Future<void> delete(String key) => _backend.delete(key: key);

  // --- bytes API -----------------------------------------------------------

  Future<void> writeBytes(String key, Uint8List value) =>
      write(key, base64Encode(value));

  Future<Uint8List?> readBytes(String key) async {
    final raw = await read(key);
    if (raw == null) return null;
    return base64Decode(raw);
  }

  // --- bulk purge --------------------------------------------------------
  //
  // Two flavours matching the two real-world scenarios:
  //
  //   [purgeSession] — the sign-out path. Clears tokens + MFA flag so the
  //   next login has to reauthenticate, but KEEPS identity state
  //   (private keys, fingerprint, user_id). This is the difference
  //   between "log out of this session" and "wipe my device": a same-
  //   account re-login on this device seamlessly picks up the local
  //   private keys and can still decrypt sealed K_files from past
  //   transfers. Without this distinction, casual sign-out would
  //   destroy the user's ability to decrypt anything sent to them.
  //
  //   [purgeAll] — the erasure / device-hand-off path. Clears everything
  //   on disk. The user is done with this device.

  Future<void> purgeSession() async {
    await Future.wait<void>([
      delete(kAccessToken),
      delete(kRefreshToken),
      delete(kMfaEnabled),
    ]);
  }

  Future<void> purgeAll() async {
    await Future.wait<void>([
      delete(kIdentityPrivate),
      delete(kIdentityPublic),
      delete(kSigningPrivate),
      delete(kSigningPublic),
      delete(kAccessToken),
      delete(kRefreshToken),
      delete(kUserId),
      delete(kEmail),
      delete(kFingerprint),
      delete(kMfaEnabled),
    ]);
  }
}
