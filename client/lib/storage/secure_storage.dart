import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Hardware-backed secret storage (spec §12B.7).
///
/// - iOS   : Keychain with `first_unlock` accessibility
/// - Android: EncryptedSharedPreferences (AES-256 GCM)
///
/// The rule: nothing sensitive touches disk except through this facade.
/// Callers that need bytes go through `readBytes`; string callers go
/// through `read`.
///
/// **Identity + signing keypairs are per-user, namespaced by user id
/// (ADR-0011).** The `..._b64.<userId>` helper functions below build
/// the actual on-disk key names; callers pass the current session's
/// user id when reading or writing. Session state — tokens, email,
/// handle, MFA flag, fingerprint — stays in single-slot storage; only
/// keypair material is per-user.
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

  // --- Session-scoped, single-slot keys ---------------------------------
  //
  // These describe the CURRENT session. Sign-out swaps them out; a
  // subsequent sign-in overwrites them. Only keypair material is
  // per-user.

  static const String kAccessToken = 'auth.access_token';
  static const String kRefreshToken = 'auth.refresh_token';
  static const String kUserId = 'auth.user_id';
  static const String kEmail = 'auth.email';
  // Optional user-picked identifier (`@alice`). Persisted so the home
  // screen can render `Signed in as … (@alice)` on cold-start without
  // hitting `/v1/users/me` again. Refreshed after every register/login.
  static const String kHandle = 'auth.handle';
  static const String kFingerprint = 'auth.fingerprint';
  static const String kMfaEnabled = 'auth.mfa_enabled';

  // --- Legacy single-slot keypair slots (M1, pre-ADR-0011) --------------
  //
  // Retained ONLY as targets for the one-time migration path below and
  // as no-op read fall-throughs. Do NOT write to these directly — all
  // new keypair persistence goes through the `..._b64.<userId>` scoped
  // helpers.

  static const String _legacyIdentityPrivate = 'auth.identity_private_b64';
  static const String _legacyIdentityPublic = 'auth.identity_public_b64';
  static const String _legacySigningPrivate = 'auth.signing_private_b64';
  static const String _legacySigningPublic = 'auth.signing_public_b64';

  // --- Per-user (scoped) keypair slots — ADR-0011 -----------------------
  //
  // Each user's keypair lives in slots keyed by their user id. This
  // means a single device can hold keys for multiple accounts without
  // one register/login overwriting another.

  /// On-disk key for a given user's X25519 identity private key.
  static String identityPrivateKeyFor(String userId) =>
      'auth.identity_private_b64.$userId';

  /// On-disk key for a given user's X25519 identity public key.
  static String identityPublicKeyFor(String userId) =>
      'auth.identity_public_b64.$userId';

  /// On-disk key for a given user's Ed25519 signing private key.
  static String signingPrivateKeyFor(String userId) =>
      'auth.signing_private_b64.$userId';

  /// On-disk key for a given user's Ed25519 signing public key.
  static String signingPublicKeyFor(String userId) =>
      'auth.signing_public_b64.$userId';

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

  // --- one-time migration (ADR-0011) --------------------------------------
  //
  // Called once at app cold-start, before restoreSession. Idempotent —
  // safe to run every launch, but only actually rewrites storage on
  // the first launch that finds legacy keys with a known kUserId.

  /// Migrate a pre-ADR-0011 single-slot keypair into the per-user
  /// scoped slots for the currently-known user, if there is one.
  ///
  /// - If legacy slots exist AND `kUserId` is set: copy each slot's
  ///   value to the corresponding scoped slot for that user, then
  ///   delete the legacy slot. Idempotent — a second call finds no
  ///   legacy slots and is a no-op.
  /// - If legacy slots exist but `kUserId` is missing: log and
  ///   leave in place. No user is impacted; the next register will
  ///   write scoped keys and the legacy slots become dead storage
  ///   (harmless). A future sweep can remove them.
  /// - If no legacy slots exist: fully no-op.
  Future<void> migrateLegacyKeypairIfNeeded() async {
    // Cheap probe first — if the first legacy key isn't there, skip
    // the rest.
    final legacyIdPriv = await read(_legacyIdentityPrivate);
    if (legacyIdPriv == null) return;

    final userId = await read(kUserId);
    if (userId == null) {
      developer.log(
        'Legacy single-slot keypair found but no kUserId set — leaving '
        'in place. Migration will run on the next successful login.',
        name: 'SecureStore.migrate',
      );
      return;
    }

    final legacyIdPub = await read(_legacyIdentityPublic);
    final legacySignPriv = await read(_legacySigningPrivate);
    final legacySignPub = await read(_legacySigningPublic);

    // Only migrate a fully-populated legacy quartet. A partial legacy
    // set (three of four present) probably indicates a botched prior
    // state; safer to leave alone than to write scoped slots that
    // won't decrypt anything anyway.
    if (legacyIdPub == null ||
        legacySignPriv == null ||
        legacySignPub == null) {
      developer.log(
        'Legacy keypair partially present (missing one or more slots) '
        '— leaving in place. Register a fresh account to establish a '
        'clean scoped keypair.',
        name: 'SecureStore.migrate',
      );
      return;
    }

    await write(identityPrivateKeyFor(userId), legacyIdPriv);
    await write(identityPublicKeyFor(userId), legacyIdPub);
    await write(signingPrivateKeyFor(userId), legacySignPriv);
    await write(signingPublicKeyFor(userId), legacySignPub);

    await delete(_legacyIdentityPrivate);
    await delete(_legacyIdentityPublic);
    await delete(_legacySigningPrivate);
    await delete(_legacySigningPublic);

    developer.log(
      'Migrated legacy single-slot keypair to scoped slots for user '
      '$userId.',
      name: 'SecureStore.migrate',
    );
  }

  // --- bulk purge --------------------------------------------------------
  //
  // Two flavours matching the two real-world scenarios:
  //
  //   [purgeSession] — the sign-out path. Clears tokens + MFA flag so the
  //   next login has to reauthenticate, but KEEPS identity state
  //   (per-user private keys, fingerprint, user_id). This is the
  //   difference between "log out of this session" and "wipe my
  //   device": a same-account re-login on this device seamlessly picks
  //   up the local private keys and can still decrypt sealed K_files
  //   from past transfers. Post ADR-0011, other users' keys stay too —
  //   a same-device account swap doesn't clobber anyone.
  //
  //   [purgeAll] — the erasure / device-hand-off path. Clears the
  //   session-scoped state. Per-user keypair slots for OTHER users on
  //   this device are NOT touched — this method only knows about the
  //   currently-active user (via kUserId). If the caller wants to nuke
  //   every keypair on the device, call this AFTER iterating known
  //   users, or use the future flutter_secure_storage `deleteAll()`.

  Future<void> purgeSession() async {
    await Future.wait<void>([
      delete(kAccessToken),
      delete(kRefreshToken),
      delete(kMfaEnabled),
    ]);
  }

  /// Delete the current session's tokens + email/handle + the scoped
  /// keypair for the currently-active user (if `kUserId` is set).
  /// Other users' keypair slots are preserved.
  Future<void> purgeAll() async {
    final userId = await read(kUserId);
    final tasks = <Future<void>>[
      delete(kAccessToken),
      delete(kRefreshToken),
      delete(kUserId),
      delete(kEmail),
      delete(kHandle),
      delete(kFingerprint),
      delete(kMfaEnabled),
    ];
    if (userId != null) {
      tasks.addAll([
        delete(identityPrivateKeyFor(userId)),
        delete(identityPublicKeyFor(userId)),
        delete(signingPrivateKeyFor(userId)),
        delete(signingPublicKeyFor(userId)),
      ]);
    }
    // Best-effort cleanup of pre-ADR-0011 legacy slots too.
    tasks.addAll([
      delete(_legacyIdentityPrivate),
      delete(_legacyIdentityPublic),
      delete(_legacySigningPrivate),
      delete(_legacySigningPublic),
    ]);
    await Future.wait(tasks);
  }

  /// Delete just the keypair slots for a specific user id. Used by
  /// the future settings-screen "forget this account on this device"
  /// affordance (ADR-0011 open follow-ups).
  Future<void> forgetUserKeypair(String userId) async {
    await Future.wait<void>([
      delete(identityPrivateKeyFor(userId)),
      delete(identityPublicKeyFor(userId)),
      delete(signingPrivateKeyFor(userId)),
      delete(signingPublicKeyFor(userId)),
    ]);
  }
}
