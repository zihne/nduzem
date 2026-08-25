import 'api_client.dart';

/// Typed wrappers over the `/v1/auth/*` surface. Every method returns a
/// domain object (a plain data class in this file) rather than the raw
/// `Map<String, dynamic>` so screens don't reach into JSON keys.
class AuthApi {
  const AuthApi(this._client);
  final ApiClient _client;

  Future<RegisterResult> register({
    required String email,
    required String password,
    required String identityPublicB64,
    required String signingPublicB64,
    String? handle,
  }) async {
    final body = await _client.post(
      '/v1/auth/register',
      body: {
        'email': email,
        'password': password,
        'identity_pub': identityPublicB64,
        'signing_pub': signingPublicB64,
        if (handle != null) 'handle': handle,
      },
    );
    return RegisterResult(
      userId: body['user_id'] as String,
      access: body['access'] as String,
      refresh: body['refresh'] as String,
      keyFingerprint: body['key_fingerprint'] as String? ?? '',
    );
  }

  /// Password-only login. Returns either a token pair (no MFA on the account)
  /// OR an `mfaSession` that the caller must submit to [loginTotp].
  Future<LoginResult> login({
    required String email,
    required String password,
  }) async {
    final body = await _client.post(
      '/v1/auth/login',
      body: {
        'email': email,
        'password': password,
      },
    );
    final mfaRequired = body['mfa_required'] == true;
    if (mfaRequired) {
      return LoginResult.mfaRequired(
        mfaSession: body['mfa_session'] as String,
      );
    }
    return LoginResult.tokens(
      access: body['access'] as String,
      refresh: body['refresh'] as String,
      emailVerified: body['email_verified'] as bool? ?? false,
    );
  }

  /// Second stage of MFA login. `code` is either a 6-digit TOTP or a
  /// single-use recovery code; `isRecovery` toggles the server-side path.
  Future<LoginResult> loginTotp({
    required String mfaSession,
    required String code,
    required bool isRecovery,
  }) async {
    final body = await _client.post(
      '/v1/auth/login/totp',
      body: {
        'mfa_session': mfaSession,
        'code': code,
        // Server field is `is_recovery_code` per LoginTotpRequest;
        // sending `is_recovery` would be silently ignored (Pydantic
        // extra=ignore) and recovery-code logins would fail.
        'is_recovery_code': isRecovery,
      },
    );
    return LoginResult.tokens(
      access: body['access'] as String,
      refresh: body['refresh'] as String,
      emailVerified: body['email_verified'] as bool? ?? false,
    );
  }

  Future<TokenPair> refresh({required String refreshToken}) async {
    final body = await _client.post(
      '/v1/auth/refresh',
      body: {'refresh': refreshToken},
    );
    return TokenPair(
      access: body['access'] as String,
      refresh: body['refresh'] as String,
    );
  }

  Future<void> verifyEmail({
    required String userId,
    required String token,
  }) async {
    await _client.post(
      '/v1/auth/verify-email',
      body: {'user_id': userId, 'token': token},
    );
  }

  /// Manual verification via the 6-digit code. Server accepts EITHER
  /// `{user_id, token}` (deep-link form, see [verifyEmail]) OR
  /// `{email, code}` — never a mix. This helper is the code form.
  Future<void> verifyEmailCode({
    required String email,
    required String code,
  }) async {
    await _client.post(
      '/v1/auth/verify-email',
      body: {'email': email, 'code': code},
    );
  }

  Future<void> resendVerification({required String email}) async {
    await _client.post('/v1/auth/resend-verification', body: {'email': email});
  }

  /// M1.7 password reset — phase 1. The server always returns
  /// `{sent: true}` regardless of whether the address exists
  /// (anti-enumeration), so this method has no meaningful return value
  /// beyond "the network call succeeded".
  Future<void> requestPasswordReset({required String email}) async {
    await _client.post(
      '/v1/auth/password-reset/request',
      body: {'email': email},
    );
  }

  /// M1.7 password reset — phase 2. Consumes the single-use link token
  /// from the reset email and swaps the password hash. Server revokes
  /// every prior refresh token as a side effect.
  Future<void> confirmPasswordReset({
    required String userId,
    required String token,
    required String newPassword,
  }) async {
    await _client.post(
      '/v1/auth/password-reset/confirm',
      body: {
        'user_id': userId,
        'token': token,
        'new_password': newPassword,
      },
    );
  }

  /// Stage 1 of MFA enrolment. Server returns the base32 secret and its
  /// `otpauth://…` URL; the user scans / types the secret into an
  /// authenticator app. `mfa_enabled` stays false on the user row until
  /// [mfaEnrollConfirm] succeeds.
  ///
  /// Recovery codes are **not** returned here — the server hands them
  /// out once at confirm time (see [MfaEnrollConfirmResult]).
  Future<TotpEnrollment> mfaEnrollBegin() async {
    final body = await _client.post('/v1/auth/mfa/enroll/begin', authed: true);
    return TotpEnrollment(
      secret: body['secret'] as String,
      otpauthUrl: body['otpauth_url'] as String,
    );
  }

  /// Stage 2 of MFA enrolment. Client proves possession of a valid TOTP;
  /// server flips `mfa_enabled=true` and hands back the one-time recovery
  /// codes. The client MUST surface them to the user immediately —
  /// hashes are stored, plaintexts cannot be retrieved later.
  Future<MfaEnrollConfirmResult> mfaEnrollConfirm({required String code}) async {
    final body = await _client.post(
      '/v1/auth/mfa/enroll/confirm',
      body: {'code': code},
      authed: true,
    );
    return MfaEnrollConfirmResult(
      mfaEnabled: body['mfa_enabled'] as bool,
      recoveryCodes:
          (body['recovery_codes'] as List<dynamic>).cast<String>().toList(),
    );
  }

  /// Turn two-factor off.
  ///
  /// Requires the account password AND a second factor — either a current
  /// TOTP or one of the recovery codes. Both, deliberately: disabling the
  /// second factor is not a lesser act than rotating an identity key, and
  /// the password is what stops someone holding only stolen session
  /// tokens from removing it. The server enforces this and rate-limits the
  /// endpoint; sending only a code returns 422.
  ///
  /// Returns the resulting state, which is `false` on success.
  Future<bool> mfaDisable({
    required String password,
    required String code,
    bool isRecoveryCode = false,
  }) async {
    final body = await _client.post(
      '/v1/auth/mfa/disable',
      body: {
        'password': password,
        'code': code,
        'is_recovery_code': isRecoveryCode,
      },
      authed: true,
    );
    return body['mfa_enabled'] as bool;
  }
}

// --- domain types -------------------------------------------------------

class RegisterResult {
  const RegisterResult({
    required this.userId,
    required this.access,
    required this.refresh,
    required this.keyFingerprint,
  });
  final String userId;
  final String access;
  final String refresh;
  final String keyFingerprint;
}

/// Result of `/v1/auth/login`: either a full token pair, or the MFA
/// challenge session that must be resolved by [AuthApi.loginTotp].
sealed class LoginResult {
  const LoginResult();

  const factory LoginResult.tokens({
    required String access,
    required String refresh,
    required bool emailVerified,
  }) = LoginTokens;

  const factory LoginResult.mfaRequired({required String mfaSession}) =
      LoginMfaRequired;
}

final class LoginTokens extends LoginResult {
  const LoginTokens({
    required this.access,
    required this.refresh,
    required this.emailVerified,
  });
  final String access;
  final String refresh;
  final bool emailVerified;
}

final class LoginMfaRequired extends LoginResult {
  const LoginMfaRequired({required this.mfaSession});
  final String mfaSession;
}

class TokenPair {
  const TokenPair({required this.access, required this.refresh});
  final String access;
  final String refresh;
}

/// Result of [AuthApi.mfaEnrollBegin]. Recovery codes are NOT included
/// here — they land in [MfaEnrollConfirmResult] after the user proves
/// possession of a working TOTP.
class TotpEnrollment {
  const TotpEnrollment({
    required this.secret,
    required this.otpauthUrl,
  });

  /// Base32 TOTP shared secret. Also embedded inside [otpauthUrl].
  final String secret;

  /// `otpauth://totp/…` URL. Render as a QR for one-tap authenticator
  /// setup, or expose "copy" so the user can paste it into their app.
  final String otpauthUrl;
}

/// Result of [AuthApi.mfaEnrollConfirm]. The recovery codes are shown
/// to the user exactly once — the server stores only their hashes.
class MfaEnrollConfirmResult {
  const MfaEnrollConfirmResult({
    required this.mfaEnabled,
    required this.recoveryCodes,
  });
  final bool mfaEnabled;
  final List<String> recoveryCodes;
}
