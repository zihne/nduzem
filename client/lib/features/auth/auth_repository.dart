import 'dart:developer' as developer;

import 'package:flutter/services.dart';

import '../../api/api_client.dart';
import '../../api/auth_api.dart';
import '../../api/users_api.dart';
import '../../crypto/fingerprint.dart';
import '../../crypto/jwt.dart';
import '../../crypto/keys.dart';
import '../../storage/secure_storage.dart';

/// Owns the authenticated-user lifecycle:
///
///   - fresh registration (generate keys, register, persist)
///   - login (with optional TOTP challenge second step)
///   - token refresh (called by ApiClient when a request 401s)
///   - sign-out (purges secure storage)
///
/// Screens don't touch [SecureStore] or the crypto layer directly; they
/// call this repository and observe the exposed [AuthSession] via the
/// Riverpod provider (see [auth_providers.dart]).
class AuthRepository implements TokenSource {
  AuthRepository({
    required AuthApi api,
    required UsersApi usersApi,
    required SecureStore storage,
    required KeypairGenerator keys,
  })  : _api = api,
        _usersApi = usersApi,
        _storage = storage,
        _keys = keys;

  final AuthApi _api;
  final UsersApi _usersApi;
  final SecureStore _storage;
  final KeypairGenerator _keys;

  // In-memory cache so the ApiClient interceptor doesn't hit the keystore
  // on every request. Warmed by [restoreSession].
  String? _accessCache;
  String? _refreshCache;

  // --- session state -------------------------------------------------------

  /// Load whatever's in secure storage into memory. Called from
  /// [`AuthNotifier.build`] at app start.
  ///
  /// **Self-heal on `BAD_DECRYPT`.** Android's EncryptedSharedPreferences
  /// (the flutter_secure_storage backend) uses a Keystore-held master
  /// key scoped to `(package, signing cert, install instance)`. If any
  /// of those changes between the write and the read — app resign
  /// (debug↔release), Google-Backup restore onto a different device,
  /// keystore glitch after an OS update — every subsequent read
  /// throws `PlatformException` with a `BadPaddingException /
  /// BAD_DECRYPT` payload. That leaves the app wedged with an
  /// unrecoverable session error that most users won't know how to
  /// clear ("clear app data" isn't discoverable). We catch that
  /// specific failure, wipe secure storage, and return a null
  /// session so the router routes to /login — same as a fresh
  /// install. User re-registers or re-logs-in, one-shot.
  ///
  /// Any other exception propagates — we don't want to silently
  /// wipe a healthy session on a transient bug.
  Future<AuthSession?> restoreSession() async {
    try {
      // ADR-0011: fold any pre-scoped single-slot keypair into the
      // per-user layout before anything reads keys. Idempotent — a
      // no-op once the device is on the scoped layout.
      await _storage.migrateLegacyKeypairIfNeeded();
      final userId = await _storage.read(SecureStore.kUserId);
      final access = await _storage.read(SecureStore.kAccessToken);
      final refresh = await _storage.read(SecureStore.kRefreshToken);
      final fp = await _storage.read(SecureStore.kFingerprint);
      final mfa = await _storage.read(SecureStore.kMfaEnabled);
      final email = await _storage.read(SecureStore.kEmail);
      final handle = await _storage.read(SecureStore.kHandle);
      if (userId == null || access == null || refresh == null) return null;
      _accessCache = access;
      _refreshCache = refresh;
      return AuthSession(
        userId: userId,
        email: email,
        handle: handle,
        fingerprint: fp ?? '',
        // Legacy sessions from before M2.5 won't have the key set —
        // default to false; the next successful login/enrol updates it.
        mfaEnabled: mfa == 'true',
      );
    } on PlatformException catch (exc) {
      if (!_isSecureStorageDecryptCorruption(exc)) rethrow;
      developer.log(
        'Secure storage returned BAD_DECRYPT at cold-start — likely '
        'master-key rotation (app resign, backup restore, or a fresh '
        'install on top of ghost state). Wiping and treating as fresh '
        'install so the user can re-register or re-log-in. Original '
        'message: ${exc.message}',
        name: 'AuthRepository.restoreSession',
        error: exc,
      );
      _accessCache = null;
      _refreshCache = null;
      await _storage.resetOnCorruption();
      return null;
    }
  }

  /// Match the shapes `flutter_secure_storage` surfaces on Android when
  /// the EncryptedSharedPreferences master key can't decrypt the on-disk
  /// blob.
  ///
  /// There are two distinct ones, and matching only the first left the
  /// app permanently wedged:
  ///
  ///   1. `javax.crypto.BadPaddingException: … BAD_DECRYPT` — raised
  ///      when the *value* ciphertext fails to decrypt.
  ///   2. `java.lang.SecurityException: Could not decrypt key.
  ///      decryption failed` — raised by Tink when the *keyset* itself
  ///      can't be unwrapped, i.e. the master key is gone or replaced.
  ///      This is what an Auto Backup restore produces: the encrypted
  ///      prefs file comes back from the cloud, the hardware-bound
  ///      master key does not.
  ///
  /// Still deliberately narrow. This predicate authorises destroying the
  /// user's private keys, so it matches decrypt-failure wording only —
  /// never a bare `SecurityException`, which would let an unrelated
  /// keystore hiccup (device locked during first unlock, for instance)
  /// wipe a healthy session.
  static bool _isSecureStorageDecryptCorruption(PlatformException exc) {
    final haystack = '${exc.code} ${exc.message ?? ''} ${exc.details ?? ''}';
    return haystack.contains('BAD_DECRYPT') ||
        haystack.contains('BadPaddingException') ||
        haystack.contains('Could not decrypt key');
  }

  /// Pull the caller's `/v1/users/me` and reconcile the local session.
  /// Called after every successful register / login — the client learns
  /// the current handle even on fresh-device sign-ins where the user only
  /// typed an email. Handle + email are persisted so a subsequent
  /// cold-start renders the same view without a re-fetch.
  ///
  /// Returns the updated `AuthSession`. Callers overwrite whatever
  /// session they built from the auth-flow result with this one before
  /// pushing it into the notifier.
  Future<AuthSession> refreshMe(AuthSession baseline) async {
    final me = await _usersApi.me();
    // Persist the two fields the home screen relies on.
    await _storage.write(SecureStore.kEmail, me.email);
    if (me.handle != null) {
      await _storage.write(SecureStore.kHandle, me.handle!);
    } else {
      await _storage.delete(SecureStore.kHandle);
    }
    return baseline.copyWith(
      email: me.email,
      handle: me.handle,
      // The server is authoritative for these two — if the caller enrolled
      // in MFA on another device, or verified their email via a link on
      // desktop, `/me` reflects reality faster than the local bit.
      mfaEnabled: me.mfaEnabled,
      emailVerified: me.emailVerified,
      erasedAt: me.erasedAt,
    );
  }

  // --- register ------------------------------------------------------------

  Future<AuthSession> register({
    required String email,
    required String password,
    String? handle,
  }) async {
    final pair = _keys.generate();
    final fp = fingerprintOf(
      identityPublic: pair.identityPublic,
      signingPublic: pair.signingPublic,
    );

    final res = await _api.register(
      email: email,
      password: password,
      identityPublicB64: pair.identityPublicB64,
      signingPublicB64: pair.signingPublicB64,
      handle: handle,
    );

    // Persist BEFORE flipping the in-memory cache — a failed write should
    // leave the app in the pre-register state so retry works. ADR-0011:
    // keypair slots are scoped to the newly-issued userId, so a second
    // account registered on this device doesn't overwrite the first.
    await _persistKeypair(userId: res.userId, pair: pair);
    await _persistTokens(
      userId: res.userId,
      access: res.access,
      refresh: res.refresh,
      fingerprint: fp.canonical,
    );
    await _storage.write(SecureStore.kEmail, email);

    _accessCache = res.access;
    _refreshCache = res.refresh;
    // Fresh account = MFA definitely not set up.
    await _writeMfaEnabled(false);
    // Caller can/should follow up with [refreshMe] to pick up the handle
    // + verified state as the server sees them; the immediate return is
    // enough for the router to leave the register screen.
    return AuthSession(
      userId: res.userId,
      email: email,
      handle: handle,
      fingerprint: fp.canonical,
      mfaEnabled: false,
    );
  }

  // --- login / TOTP --------------------------------------------------------

  /// Password-only login. Two outcomes:
  ///   - [LoginOutcomeTokens]: tokens issued; caller should
  ///     `setSession(outcome.session)` and route based on
  ///     `outcome.emailVerified` (`true` → `/`, `false` → `/verify-email`).
  ///   - [LoginOutcomeMfaRequired]: caller must resolve the MFA challenge
  ///     by calling [loginTotp] with the `mfaSession`.
  ///
  /// On the tokens branch, this method has already persisted the tokens +
  /// user id to secure storage before returning.
  Future<LoginOutcome> login({
    required String email,
    required String password,
  }) async {
    final result = await _api.login(email: email, password: password);
    // Persist the email as soon as the server accepts the credentials
    // (whether the tokens branch or the MFA-required branch fires next).
    // `loginTotp` then reads it back from storage — the TOTP screen no
    // longer needs a re-entry.
    await _storage.write(SecureStore.kEmail, email);
    return switch (result) {
      LoginMfaRequired(:final mfaSession) =>
        LoginOutcome.mfaRequired(mfaSession),
      LoginTokens(:final access, :final refresh, :final emailVerified) =>
        LoginOutcome.tokens(
          // Server issued tokens without an MFA challenge → MFA is off.
          await _acceptTokens(
            access: access,
            refresh: refresh,
            mfaEnabled: false,
          ),
          emailVerified,
        ),
    };
  }

  /// Second stage of MFA login. Returns the same [LoginOutcome.tokens]
  /// shape as [login] so the caller can navigate the same way.
  Future<LoginOutcome> loginTotp({
    required String mfaSession,
    required String code,
    required bool isRecovery,
  }) async {
    final result = await _api.loginTotp(
      mfaSession: mfaSession,
      code: code,
      isRecovery: isRecovery,
    );
    if (result is! LoginTokens) {
      throw StateError(
        'Server returned a non-tokens LoginResult from /login/totp.',
      );
    }
    return LoginOutcome.tokens(
      // We just completed a TOTP challenge → MFA is definitely on.
      await _acceptTokens(
        access: result.access,
        refresh: result.refresh,
        mfaEnabled: true,
      ),
      result.emailVerified,
    );
  }

  /// Common tail for both password-only and TOTP logins: persist the
  /// tokens, decode the user id out of the access JWT's `sub` claim, save
  /// it, and build an [AuthSession] using whatever fingerprint is already
  /// on-device (from a prior register on this device). Fingerprint stays
  /// empty on a fresh install — that's a multi-device concern for M2+.
  Future<AuthSession> _acceptTokens({
    required String access,
    required String refresh,
    required bool mfaEnabled,
  }) async {
    await _persistTokensOnly(access: access, refresh: refresh);
    final userId = extractSubject(access);
    await _storage.write(SecureStore.kUserId, userId);
    await _writeMfaEnabled(mfaEnabled);
    final fp = await _storage.read(SecureStore.kFingerprint) ?? '';
    final email = await _storage.read(SecureStore.kEmail);
    final handle = await _storage.read(SecureStore.kHandle);
    return AuthSession(
      userId: userId,
      email: email,
      handle: handle,
      fingerprint: fp,
      mfaEnabled: mfaEnabled,
    );
  }

  Future<void> _writeMfaEnabled(bool value) =>
      _storage.write(SecureStore.kMfaEnabled, value ? 'true' : 'false');

  /// Public setter for the notifier to update on successful enrol.
  Future<void> setMfaEnabled(bool value) => _writeMfaEnabled(value);

  // --- verify email --------------------------------------------------------

  Future<void> verifyEmail({required String userId, required String token}) =>
      _api.verifyEmail(userId: userId, token: token);

  Future<void> verifyEmailCode({
    required String email,
    required String code,
  }) =>
      _api.verifyEmailCode(email: email, code: code);

  Future<void> resendVerification({required String email}) =>
      _api.resendVerification(email: email);

  // --- password reset (M1.7) ----------------------------------------------

  /// Anti-enumeration by design on the server: this always resolves to a
  /// void success unless the network itself fails. The screen shows a
  /// generic "if the address exists, check your email" message either way.
  Future<void> requestPasswordReset({required String email}) =>
      _api.requestPasswordReset(email: email);

  /// Consumes the single-use reset token. On success, the server has
  /// already revoked every prior refresh token — but the caller's own
  /// tokens don't exist yet (unauthenticated flow), so nothing to purge
  /// locally beyond the standard signed-out state.
  Future<void> confirmPasswordReset({
    required String userId,
    required String token,
    required String newPassword,
  }) =>
      _api.confirmPasswordReset(
        userId: userId,
        token: token,
        newPassword: newPassword,
      );

  // --- MFA enrolment -------------------------------------------------------

  Future<TotpEnrollment> mfaEnrollBegin() => _api.mfaEnrollBegin();

  /// Returns the one-time recovery codes; the caller MUST surface them
  /// to the user before navigating away — the server stores only hashes.
  Future<MfaEnrollConfirmResult> mfaEnrollConfirm({required String code}) =>
      _api.mfaEnrollConfirm(code: code);

  // --- sign out ------------------------------------------------------------

  /// Session-level sign-out: clears tokens + the MFA-enabled flag so the
  /// next login has to re-authenticate. **Preserves** the per-user
  /// keypair slots (ADR-0011), the user id, and fingerprint so a
  /// subsequent login by the same user on this device can still decrypt
  /// K_files sealed under those keys. Other users' keypair slots are
  /// untouched. See [SecureStore.purgeSession] for the rationale.
  Future<void> signOut() async {
    _accessCache = null;
    _refreshCache = null;
    await _storage.purgeSession();
  }

  // --- TokenSource for ApiClient ------------------------------------------

  @override
  Future<String?> readAccessToken() async {
    return _accessCache ?? await _storage.read(SecureStore.kAccessToken);
  }

  @override
  Future<String?> refreshAccessToken() async {
    final refresh =
        _refreshCache ?? await _storage.read(SecureStore.kRefreshToken);
    if (refresh == null) return null;
    try {
      final pair = await _api.refresh(refreshToken: refresh);
      await _persistTokensOnly(access: pair.access, refresh: pair.refresh);
      return pair.access;
    } on ApiException {
      // Refresh itself failed (401/403 typically). Purge and let the caller
      // bounce to login. Do NOT rethrow — the caller in ApiClient treats
      // null as "give up on retry."
      await signOut();
      return null;
    }
  }

  // --- internals -----------------------------------------------------------

  /// ADR-0011: keypair material is namespaced by `userId` so two
  /// accounts registered on the same device don't clobber each other.
  Future<void> _persistKeypair({
    required String userId,
    required IdentityKeypair pair,
  }) async {
    await _storage.writeBytes(
      SecureStore.identityPrivateKeyFor(userId),
      pair.identityPrivate,
    );
    await _storage.writeBytes(
      SecureStore.identityPublicKeyFor(userId),
      pair.identityPublic,
    );
    await _storage.writeBytes(
      SecureStore.signingPrivateKeyFor(userId),
      pair.signingPrivate,
    );
    await _storage.writeBytes(
      SecureStore.signingPublicKeyFor(userId),
      pair.signingPublic,
    );
  }

  Future<void> _persistTokens({
    required String userId,
    required String access,
    required String refresh,
    required String fingerprint,
  }) async {
    await _storage.write(SecureStore.kUserId, userId);
    await _storage.write(SecureStore.kAccessToken, access);
    await _storage.write(SecureStore.kRefreshToken, refresh);
    await _storage.write(SecureStore.kFingerprint, fingerprint);
  }

  Future<void> _persistTokensOnly({
    required String access,
    required String refresh,
  }) async {
    _accessCache = access;
    _refreshCache = refresh;
    await _storage.write(SecureStore.kAccessToken, access);
    await _storage.write(SecureStore.kRefreshToken, refresh);
  }
}

/// Snapshot of the signed-in user. Populated first from local secure
/// storage (fast path on cold-start) and then reconciled against
/// `/v1/users/me` after every register / login (ADR-0032) so fields the
/// server owns — verified state, MFA, handle on a fresh device — are
/// authoritative.
class AuthSession {
  const AuthSession({
    required this.userId,
    required this.email,
    required this.handle,
    required this.fingerprint,
    required this.mfaEnabled,
    this.emailVerified = false,
    this.erasedAt,
  });
  final String userId;

  /// Email the user typed at register/login OR fetched from `/me`. Null
  /// for legacy sessions that predate M2.x.
  final String? email;

  /// User-picked identifier (`@alice`). Null when the user never set one
  /// at register, or when this device hasn't refreshed `/me` yet.
  final String? handle;

  /// User's key fingerprint in canonical form (25 decimal digits, no spaces)
  /// matching `Fingerprint.canonical`. Empty when we don't have it locally
  /// (e.g. logged in on a device that never registered — a multi-device
  /// concern for M2+).
  final String fingerprint;

  /// True when the account has TOTP MFA enabled. Populated from the
  /// login/enrol flow and re-confirmed from `/me` after every sign-in.
  final bool mfaEnabled;

  /// True when the server has recorded a verified email. Drives the
  /// "verify your email" banner on the home screen. Defaults to false
  /// on cold-restore; `refreshMe` supplies the truth from the server.
  final bool emailVerified;

  /// Non-null when the caller's account is tombstoned (M9.5). Home
  /// screen renders an "your account has been erased" state and clears
  /// local session data instead of attempting normal navigation.
  final DateTime? erasedAt;

  AuthSession copyWith({
    String? userId,
    String? email,
    String? handle,
    String? fingerprint,
    bool? mfaEnabled,
    bool? emailVerified,
    DateTime? erasedAt,
  }) =>
      AuthSession(
        userId: userId ?? this.userId,
        email: email ?? this.email,
        handle: handle ?? this.handle,
        fingerprint: fingerprint ?? this.fingerprint,
        mfaEnabled: mfaEnabled ?? this.mfaEnabled,
        emailVerified: emailVerified ?? this.emailVerified,
        erasedAt: erasedAt ?? this.erasedAt,
      );
}

/// Result of [AuthRepository.login] / [AuthRepository.loginTotp]. Screens
/// pattern-match on this to decide whether to route to `/`, `/verify-email`,
/// or `/login/totp`.
sealed class LoginOutcome {
  const LoginOutcome();

  const factory LoginOutcome.tokens(AuthSession session, bool emailVerified) =
      LoginOutcomeTokens;

  const factory LoginOutcome.mfaRequired(String mfaSession) =
      LoginOutcomeMfaRequired;
}

final class LoginOutcomeTokens extends LoginOutcome {
  const LoginOutcomeTokens(this.session, this.emailVerified);
  final AuthSession session;
  final bool emailVerified;
}

final class LoginOutcomeMfaRequired extends LoginOutcome {
  const LoginOutcomeMfaRequired(this.mfaSession);
  final String mfaSession;
}

