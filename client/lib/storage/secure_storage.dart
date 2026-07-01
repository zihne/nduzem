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
  static const String kSigningPrivate = 'auth.signing_private_b64';
  static const String kAccessToken = 'auth.access_token';
  static const String kRefreshToken = 'auth.refresh_token';
  static const String kUserId = 'auth.user_id';
  static const String kFingerprintHex = 'auth.fingerprint_hex';

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

  // --- bulk purge (used on logout / erasure) -------------------------------

  Future<void> purgeAuth() async {
    await Future.wait<void>([
      delete(kIdentityPrivate),
      delete(kSigningPrivate),
      delete(kAccessToken),
      delete(kRefreshToken),
      delete(kUserId),
      delete(kFingerprintHex),
    ]);
  }
}
