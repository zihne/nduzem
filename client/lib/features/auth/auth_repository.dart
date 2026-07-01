import '../../api/api_client.dart';
import '../../api/auth_api.dart';
import '../../crypto/fingerprint.dart';
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
    required SecureStore storage,
    required KeypairGenerator keys,
  })  : _api = api,
        _storage = storage,
        _keys = keys;

  final AuthApi _api;
  final SecureStore _storage;
  final KeypairGenerator _keys;

  // In-memory cache so the ApiClient interceptor doesn't hit the keystore
  // on every request. Warmed by [restoreSession].
  String? _accessCache;
  String? _refreshCache;

  // --- session state -------------------------------------------------------

  /// Load whatever's in secure storage into memory. Called from
  /// [`AuthNotifier.build`] at app start.
  Future<AuthSession?> restoreSession() async {
    final userId = await _storage.read(SecureStore.kUserId);
    final access = await _storage.read(SecureStore.kAccessToken);
    final refresh = await _storage.read(SecureStore.kRefreshToken);
    final fp = await _storage.read(SecureStore.kFingerprintHex);
    if (userId == null || access == null || refresh == null) return null;
    _accessCache = access;
    _refreshCache = refresh;
    return AuthSession(userId: userId, fingerprintHex: fp ?? '');
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
    // leave the app in the pre-register state so retry works.
    await _persistKeypair(pair);
    await _persistTokens(
      userId: res.userId,
      access: res.access,
      refresh: res.refresh,
      fingerprintHex: fp.rawHex,
    );

    _accessCache = res.access;
    _refreshCache = res.refresh;
    return AuthSession(userId: res.userId, fingerprintHex: fp.rawHex);
  }

  // --- login / TOTP --------------------------------------------------------

  Future<LoginResult> login({
    required String email,
    required String password,
  }) async {
    final result = await _api.login(email: email, password: password);
    if (result is LoginTokens) {
      await _persistTokensOnly(access: result.access, refresh: result.refresh);
    }
    return result;
  }

  Future<AuthSession> loginTotp({
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
    await _persistTokensOnly(access: result.access, refresh: result.refresh);
    final userId = await _storage.read(SecureStore.kUserId) ?? '';
    final fp = await _storage.read(SecureStore.kFingerprintHex) ?? '';
    return AuthSession(userId: userId, fingerprintHex: fp);
  }

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

  // --- MFA enrolment -------------------------------------------------------

  Future<TotpEnrollment> mfaEnrollBegin() => _api.mfaEnrollBegin();

  Future<void> mfaEnrollConfirm({required String code}) =>
      _api.mfaEnrollConfirm(code: code);

  // --- sign out ------------------------------------------------------------

  Future<void> signOut() async {
    _accessCache = null;
    _refreshCache = null;
    await _storage.purgeAuth();
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

  Future<void> _persistKeypair(IdentityKeypair pair) async {
    await _storage.writeBytes(SecureStore.kIdentityPrivate, pair.identityPrivate);
    await _storage.writeBytes(SecureStore.kSigningPrivate, pair.signingPrivate);
  }

  Future<void> _persistTokens({
    required String userId,
    required String access,
    required String refresh,
    required String fingerprintHex,
  }) async {
    await _storage.write(SecureStore.kUserId, userId);
    await _storage.write(SecureStore.kAccessToken, access);
    await _storage.write(SecureStore.kRefreshToken, refresh);
    await _storage.write(SecureStore.kFingerprintHex, fingerprintHex);
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

/// Snapshot of the signed-in user. Kept minimal — anything screen-specific
/// (email, handle, verification state) is fetched on demand rather than
/// cached in this repository.
class AuthSession {
  const AuthSession({required this.userId, required this.fingerprintHex});
  final String userId;
  final String fingerprintHex;
}

