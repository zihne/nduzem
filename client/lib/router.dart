import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'features/auth/auth_providers.dart';
import 'features/auth/login_screen.dart';
import 'features/auth/password_reset_confirm_screen.dart';
import 'features/auth/password_reset_request_screen.dart';
import 'features/auth/register_screen.dart';
import 'features/auth/totp_challenge_screen.dart';
import 'features/auth/totp_enroll_screen.dart';
import 'features/auth/verify_email_screen.dart';
import 'features/home/home_screen.dart';
import 'features/verify_contact/verify_contact_screen.dart';

/// Application routing tree.
///
/// The router reads `authSessionProvider` and redirects on session state:
///
///   - unauthenticated user → `/login` (except the register /
///     verify-email / password-reset paths, which are self-serve
///     pre-auth surfaces)
///   - authenticated user hitting `/login` or `/register` → `/`
///
/// Deep links land on `/verify-email?user_id=…&token=…` (M1.5) or
/// `/password-reset?user_id=…&token=…` (M1.7). Both custom-scheme and
/// universal / app-link URIs converge here.
final routerProvider = Provider<GoRouter>((ref) {
  final refresh = _AuthRefreshListenable(ref);
  return GoRouter(
    initialLocation: '/',
    refreshListenable: refresh,
    redirect: (context, state) {
      final session = ref.read(authSessionProvider);
      // While the initial keystore probe is in flight, hold on `/` — the
      // splash-y HomeScreen renders a spinner and reroutes when the value
      // arrives.
      if (session.isLoading) return null;
      final isSignedIn = session.value != null;
      final path = state.uri.path;

      final atAuthSurface = path == '/login' ||
          path == '/register' ||
          path == '/login/totp' ||
          path == '/verify-email' ||
          path == '/password-reset';
      if (!isSignedIn && !atAuthSurface) return '/login';
      if (isSignedIn && (path == '/login' || path == '/register')) return '/';
      return null;
    },
    routes: [
      GoRoute(path: '/', builder: (_, __) => const HomeScreen()),
      GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),
      GoRoute(path: '/register', builder: (_, __) => const RegisterScreen()),
      GoRoute(
        path: '/login/totp',
        builder: (context, state) {
          final session = state.uri.queryParameters['session'] ?? '';
          return TotpChallengeScreen(mfaSession: session);
        },
      ),
      GoRoute(
        path: '/verify-email',
        builder: (context, state) {
          final q = state.uri.queryParameters;
          final userId = q['user_id'] ?? '';
          return VerifyEmailScreen(
            userId: userId,
            email: q['email'],
            token: q['token'],
          );
        },
      ),
      GoRoute(
        path: '/mfa/enroll',
        builder: (_, __) => const TotpEnrollScreen(),
      ),
      // M2.5 out-of-band contact verification.
      GoRoute(
        path: '/verify-contact',
        builder: (_, __) => const VerifyContactScreen(),
      ),
      // M1.7 password-reset. Backend link is
      // `/password-reset?user_id=…&token=…` — same path handles both
      // phases: with the token pair it shows the "choose new password"
      // form; without, it shows the "enter your email" form.
      GoRoute(
        path: '/password-reset',
        builder: (context, state) {
          final q = state.uri.queryParameters;
          final userId = q['user_id'];
          final token = q['token'];
          if (userId != null && token != null) {
            return PasswordResetConfirmScreen(userId: userId, token: token);
          }
          return const PasswordResetRequestScreen();
        },
      ),
    ],
  );
});

/// Bridges Riverpod's `authSessionProvider` change events to go_router's
/// `refreshListenable`, which expects a `Listenable`. Without this the
/// router won't re-evaluate `redirect` after sign-in/out.
class _AuthRefreshListenable extends ChangeNotifier {
  _AuthRefreshListenable(this._ref) {
    _sub = _ref.listen(authSessionProvider, (_, __) => notifyListeners());
  }

  final Ref _ref;
  late final ProviderSubscription<Object?> _sub;

  @override
  void dispose() {
    _sub.close();
    super.dispose();
  }
}
