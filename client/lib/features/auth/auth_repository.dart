import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/services.dart';

import '../../api/api_client.dart';
import '../../api/auth_api.dart';
import '../../api/users_api.dart';
import '../../crypto/fingerprint.dart';
import '../../crypto/jwt.dart';
import '../../crypto/keys.dart';
import '../../crypto/recovery_key.dart';
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
        fingerprint: await _deriveFingerprint(userId),
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
      // Re-derived, not carried over. The fingerprint is a pure function
      // of the keypair on THIS device, and the two callers that matter
      // most call `refreshMe` precisely because that keypair just
      // changed: restore-from-recovery-key installs one where there was
      // none, and rotation replaces it.
      //
      // Carrying `baseline.fingerprint` through meant neither took
      // effect until the next sign-in (which re-runs `restoreSession`,
      // which does derive). After a restore the home screen kept seeing
      // an empty fingerprint and kept offering "Restore from recovery
      // key" for a key that was already on disk; after a rotation it
      // kept displaying the superseded safety number, which is the one
      // value that must never be stale — a user reading it aloud for
      // out-of-band verification would give a number that no longer
      // matches their published key.
      fingerprint: await _deriveFingerprint(baseline.userId),
      // The server is authoritative for these two — if the caller enrolled
      // in MFA on another device, or verified their email via a link on
      // desktop, `/me` reflects reality faster than the local bit.
      mfaEnabled: me.mfaEnabled,
      emailVerified: me.emailVerified,
      erasedAt: me.erasedAt,
    );
  }

  /// Derive this user's fingerprint from their stored public keys.
  ///
  /// The fingerprint used to be read from `kFingerprint`, a value cached
  /// at register time. Two bugs followed from caching a derived value:
  ///
  /// 1. **It went stale.** Widening the safety number from 60 bits
  ///    (ADR-0016 era) changed what `fingerprintOf` returns, but a cached
  ///    string cannot change. Existing users saw the OLD fingerprint on
  ///    the home screen while `send_screen` and `verify_contact_screen`
  ///    computed the NEW one — so a user reading their own number aloud
  ///    for out-of-band verification gave the recipient a value that
  ///    could never match the lookup. That defeats the only defence
  ///    against a server substituting keys.
  ///
  /// 2. **It was single-slot while keypairs are per-user (ADR-0011).**
  ///    On a device hosting two accounts, the displayed fingerprint
  ///    belonged to whichever registered last.
  ///
  /// Deriving on read makes both impossible: it is a pure function of
  /// the two public keys, so it cannot disagree with what the send path
  /// computes and cannot belong to a different account.
  ///
  /// Returns '' when the keypair isn't on this device — a fresh install
  /// that logged in rather than registered. The UI already renders an
  /// empty fingerprint as "not available", which is honest: without the
  /// keys there is nothing to verify.
  Future<String> _deriveFingerprint(String userId) async {
    final identityPub = await _storage.readBytes(
      SecureStore.identityPublicKeyFor(userId),
    );
    final signingPub = await _storage.readBytes(
      SecureStore.signingPublicKeyFor(userId),
    );
    if (identityPub == null || signingPub == null) return '';
    return fingerprintOf(
      identityPublic: identityPub,
      signingPublic: signingPub,
    ).canonical;
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
  /// it, and build an [AuthSession].
  ///
  /// The fingerprint is DERIVED from this user's stored public keys, not
  /// read back from a cache — see [_deriveFingerprint]. It stays empty on
  /// a fresh install that logged in rather than registered, because the
  /// keypair isn't on this device to derive from.
  Future<AuthSession> _acceptTokens({
    required String access,
    required String refresh,
    required bool mfaEnabled,
  }) async {
    await _persistTokensOnly(access: access, refresh: refresh);
    final userId = extractSubject(access);
    await _storage.write(SecureStore.kUserId, userId);
    await _writeMfaEnabled(mfaEnabled);
    final email = await _storage.read(SecureStore.kEmail);
    final handle = await _storage.read(SecureStore.kHandle);
    return AuthSession(
      userId: userId,
      email: email,
      handle: handle,
      fingerprint: await _deriveFingerprint(userId),
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

  /// Turn two-factor off. Requires the account password AND a second
  /// factor — see [AuthApi.mfaDisable] for why both.
  ///
  /// Persists the flag on success so the home screen shows "Enable
  /// two-factor" again without waiting for a `/me` refresh. The local
  /// write happens only when the server confirms, so a failed attempt
  /// cannot desynchronise the two.
  Future<bool> mfaDisable({
    required String password,
    required String code,
    bool isRecoveryCode = false,
  }) async {
    final stillEnabled = await _api.mfaDisable(
      password: password,
      code: code,
      isRecoveryCode: isRecoveryCode,
    );
    if (!stillEnabled) await _writeMfaEnabled(false);
    return stillEnabled;
  }

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

  /// Non-null while a refresh is in flight. See [refreshAccessToken].
  Future<String?>? _refreshInFlight;

  @override
  Future<String?> refreshAccessToken() {
    // SINGLE-FLIGHT, and not merely as an optimisation.
    //
    // The server rotates refresh tokens on every use AND treats the reuse
    // of an already-rotated token as theft: it revokes the entire token
    // FAMILY and commits that before returning 401 (server
    // `api/v1/auth.py`, "Theft detection").
    //
    // So two concurrent 401s racing here would each read the same cached
    // refresh token and call the endpoint twice. The first rotates and
    // mints a replacement; the second replays the now-rotated token, the
    // server revokes the whole family — including the token just minted —
    // and the `on ApiException` branch below signs out a session that was
    // valid a millisecond earlier.
    //
    // Concurrent 401s are ordinary, not exotic: an app resume or a screen
    // firing several requests at once produces exactly this. Callers must
    // therefore share one refresh rather than each starting their own.
    return _refreshInFlight ??= _performRefresh().whenComplete(() {
      _refreshInFlight = null;
    });
  }

  Future<String?> _performRefresh() async {
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

  // --- identity key rotation -----------------------------------------------

  /// Generate a fresh identity + signing keypair and publish it
  /// (server ADR-0017, client ADR-0017).
  ///
  /// **Ordering is the whole design here.** The new private keys are
  /// written to secure storage BEFORE the server is told about the new
  /// public keys. Publish-then-persist has a window where the account
  /// PUBLISHES a key this device cannot use — `POST /v1/users/lookup`
  /// would hand it to senders immediately, and they would seal files the
  /// user cannot open, leaving them worse off than before rotating,
  /// which is a cruel outcome for an operation whose entire purpose is
  /// recovering from key loss.
  ///
  /// Persist-then-publish inverts the failure into a harmless one: local
  /// keys the server has not heard of yet. Nothing seals to them, and
  /// retrying the call fixes it.
  ///
  /// The old private keys are deliberately NOT deleted. If any remain,
  /// they are the only thing that can still open transfers already
  /// sealed to them, and rotation is not a reason to destroy readable
  /// mail. They are simply superseded.
  Future<IdentityKeyRotation> rotateIdentityKey({
    required String password,
    String? mfaCode,
    bool mfaIsRecoveryCode = false,
  }) async {
    final userId = await _storage.read(SecureStore.kUserId);
    if (userId == null) {
      throw StateError('Not signed in.');
    }

    final pair = _keys.generate();
    final fp = fingerprintOf(
      identityPublic: pair.identityPublic,
      signingPublic: pair.signingPublic,
    );

    await _persistKeypair(userId: userId, pair: pair);

    final result = await _usersApi.rotateIdentityKey(
      password: password,
      identityPublicB64: pair.identityPublicB64,
      signingPublicB64: pair.signingPublicB64,
      mfaCode: mfaCode,
      mfaIsRecoveryCode: mfaIsRecoveryCode,
    );

    // Cross-check rather than trust the echo. The server independently
    // derives the fingerprint from the keys it stored; if its answer
    // differs from ours, either it stored something other than what we
    // sent or the two derivations have drifted. Both are exactly the
    // condition out-of-band verification exists to catch, so surface it
    // instead of displaying a number our contacts will not see.
    if (result.keyFingerprint.replaceAll(' ', '') != fp.canonical) {
      throw StateError(
        'The server reported a different fingerprint (${result.keyFingerprint}) '
        'than this device computed (${fp.display}). The key was not stored as '
        'sent — do not share either value.',
      );
    }

    await _storage.write(SecureStore.kFingerprint, fp.canonical);
    return result;
  }

  // --- encrypted key backup / recovery (ADR-0017) --------------------------

  /// Generate a recovery key, wrap this device's keypair under it, and
  /// upload the result.
  ///
  /// The returned [RecoveryKey] is the ONLY copy that will ever exist.
  /// It is not persisted here and not sent anywhere — the caller must
  /// show it to the user, and once that screen is dismissed it is gone.
  /// That is the whole design: the server holds ciphertext it has no key
  /// for, so nobody, including us, can recover the account without it.
  Future<RecoveryKey> createKeyBackup({required String password}) async {
    final userId = await _storage.read(SecureStore.kUserId);
    if (userId == null) throw StateError('Not signed in.');

    final pair = await _loadKeypair(userId);
    if (pair == null) {
      // Backing up a key this device does not have would produce a
      // backup of nothing, and the user would believe they were
      // protected. Fail plainly instead.
      throw StateError(
        'This device does not hold the keys for this account, so there is '
        'nothing to back up. Sign in where the keys are, or restore from '
        'an existing backup first.',
      );
    }

    final sodium = _keys.sodium;
    final recovery = RecoveryKey.generate(sodium);
    final fingerprint = fingerprintOf(
      identityPublic: pair.identityPublic,
      signingPublic: pair.signingPublic,
    ).canonical;

    // Refuse to back up a key the account no longer publishes.
    //
    // This check used to exist only on RESTORE, and the asymmetry was the
    // bug: a device holding a superseded keypair — rotation happened
    // elsewhere, and this device has not learned of it — could produce a
    // backup that was already useless, upload it, and report success. The
    // user discovered it at restore time, which is months later, on a
    // different device, at the one moment they have no alternative.
    //
    // Failing here instead is strictly better: the working key is still
    // in front of them and they can act. Failing at restore is finding
    // out the parachute does not open.
    //
    // Same source as the restore check — derived from the public key
    // BYTES the directory returns, not the server's claimed fingerprint —
    // and the same tolerance: an unreachable directory returns null and
    // does not block the backup. Someone taking a backup may well be
    // doing so because something is already wrong.
    final published = await _publishedFingerprint();
    if (published != null && published != fingerprint) {
      throw SupersededKeyBackup(
        deviceFingerprint: Fingerprint(fingerprint).display,
        publishedFingerprint: Fingerprint(published).display,
      );
    }

    final blob = wrapKeypairForBackup(
      sodium: sodium,
      recovery: recovery,
      pair: pair,
      fingerprint: fingerprint,
    );

    await _usersApi.putKeyBackup(
      blobB64: base64Encode(blob),
      password: password,
    );
    return recovery;
  }

  /// Fetch the backup and unwrap it with [recovery], then persist the
  /// keypair locally.
  ///
  /// Before writing anything, checks the restored key against the
  /// public key the account currently PUBLISHES — the one
  /// `POST /v1/users/lookup` hands to senders so they know what to seal
  /// to. An old backup, taken before a key rotation, unwraps perfectly
  /// and yields a keypair nobody sends to any more; without this check
  /// the restore reports success and then decrypts nothing, which is a
  /// miserable thing to diagnose from a support email.
  ///
  /// Checked against the SERVER rather than this device's cached
  /// fingerprint, because in a restore the device's local state is
  /// precisely what is missing. Note this catches the honest case — a
  /// rotation after the backup — and not a lying server: one that
  /// returned someone else's keys would produce a false mismatch, which
  /// is the trust problem senders already have (whitepaper §5.2). What
  /// it cannot do is make a wrong restore succeed; the unwrap is
  /// authenticated by the recovery key.
  Future<RestoredKeypair> restoreFromKeyBackup(RecoveryKey recovery) async {
    final userId = await _storage.read(SecureStore.kUserId);
    if (userId == null) throw StateError('Not signed in.');

    final blobB64 = await _usersApi.getKeyBackupBlob();
    if (blobB64 == null) {
      throw StateError('This account has no key backup to restore from.');
    }

    final sodium = _keys.sodium;
    final restored = unwrapKeypairFromBackup(
      sodium: sodium,
      recovery: recovery,
      blob: Uint8List.fromList(base64Decode(blobB64)),
    );

    final derived = fingerprintOf(
      identityPublic: restored.pair.identityPublic,
      signingPublic: restored.pair.signingPublic,
    );
    final published = await _publishedFingerprint();
    if (published != null && published != derived.canonical) {
      throw StaleKeyBackup(
        backupFingerprint: derived.display,
        currentFingerprint: Fingerprint(published).display,
      );
    }

    await _persistKeypair(userId: userId, pair: restored.pair);
    await _storage.write(SecureStore.kFingerprint, derived.canonical);
    return restored;
  }

  Future<KeyBackupStatus> keyBackupStatus() => _usersApi.keyBackupStatus();

  Future<void> deleteKeyBackup({required String password}) async {
    await _usersApi.deleteKeyBackup(password: password);
  }

  /// Erase the account (GDPR Art. 17) and destroy every local trace of
  /// it. Irreversible on both sides.
  ///
  /// Two ordering decisions, both deliberate:
  ///
  /// **The server call comes first.** Purging local state before the
  /// request would mean a network failure, a wrong password, or a
  /// moderation hold leaves the user signed out of an account that
  /// still exists, with their identity keys already destroyed — every
  /// transfer ever sealed to them unreadable, for an operation that
  /// did not happen. Local teardown only runs once the server has
  /// confirmed.
  ///
  /// **`purgeAll`, not `purgeSession`.** Sign-out keeps the keypair so
  /// the user can sign back in and still read their mail. Here the
  /// account is gone, so the keys unlock nothing — and leaving private
  /// keys on the device after "delete my account" would contradict
  /// what the user was told. Other accounts' key slots on the same
  /// device are preserved (ADR-0011); only this one is destroyed.
  Future<ErasureReceipt> eraseAccount({required String password}) async {
    final receipt = await _usersApi.eraseAccount(password: password);
    _accessCache = null;
    _refreshCache = null;
    await _storage.purgeAll();
    return receipt;
  }

  /// The fingerprint of the public key this account currently
  /// PUBLISHES via `POST /v1/users/lookup` — i.e. what a sender would
  /// seal a file to right now. Fetched rather than read from local
  /// state, because local state is exactly what is missing in the
  /// situation a restore addresses.
  Future<String?> _publishedFingerprint() async {
    try {
      final me = await _usersApi.me();
      final handle = me.handle;
      if (handle == null) return null;
      final found = await _usersApi.lookup(handle: handle);
      // Derive from the returned PUBLIC KEY BYTES rather than reading
      // the server's own `serverKeyFingerprint` field. The lookup
      // returns raw key bytes for exactly this reason: taking the
      // server's word for a key/fingerprint binding would defeat the
      // check being made here.
      return fingerprintOf(
        identityPublic: found.identityPublic,
        signingPublic: found.signingPublic,
      ).canonical;
    } on Object {
      // A lookup we cannot complete is not a reason to refuse a
      // restore — the user may be recovering precisely because things
      // are broken. The unwrap is authenticated on its own, so the
      // worst case is proceeding without the staleness warning.
      return null;
    }
  }

  Future<IdentityKeypair?> _loadKeypair(String userId) async {
    final ip = await _storage.readBytes(SecureStore.identityPrivateKeyFor(userId));
    final iu = await _storage.readBytes(SecureStore.identityPublicKeyFor(userId));
    final sp = await _storage.readBytes(SecureStore.signingPrivateKeyFor(userId));
    final su = await _storage.readBytes(SecureStore.signingPublicKeyFor(userId));
    if (ip == null || iu == null || sp == null || su == null) return null;
    return IdentityKeypair(
      identityPublic: iu,
      identityPrivate: ip,
      signingPublic: su,
      signingPrivate: sp,
    );
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
    // Still written for older builds and any external reader that
    // expects the key, but NOTHING reads it back as the source of truth
    // any more — it is derived on every session build. Leaving a cached
    // copy in place that could disagree with the derived value is the
    // bug this replaced, so treat this write as legacy and do not
    // reintroduce a read of it. `wipe()` still clears it.
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
