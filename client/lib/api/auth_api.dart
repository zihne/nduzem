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
        'is_recovery': isRecovery,
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

  /// Enrol TOTP: authed call returns a base32 secret + otpauth URI +
  /// one-time recovery codes. The recovery codes are shown ONCE to the user
  /// and never returned again.
  Future<TotpEnrollment> mfaEnrollBegin() async {
    final body = await _client.post('/v1/auth/mfa/enroll/begin', authed: true);
    return TotpEnrollment(
      secretBase32: body['secret_base32'] as String,
      otpauthUri: body['otpauth_uri'] as String,
      recoveryCodes: (body['recovery_codes'] as List<dynamic>)
          .cast<String>()
          .toList(),
    );
  }

  /// Confirm enrolment by proving possession of a working TOTP.
  Future<void> mfaEnrollConfirm({required String code}) async {
    await _client.post(
      '/v1/auth/mfa/enroll/confirm',
      body: {'code': code},
      authed: true,
    );
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

class TotpEnrollment {
  const TotpEnrollment({
    required this.secretBase32,
    required this.otpauthUri,
    required this.recoveryCodes,
  });
  final String secretBase32;
  final String otpauthUri;
  final List<String> recoveryCodes;
}
