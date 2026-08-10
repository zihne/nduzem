import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'features/auth/auth_providers.dart';
import 'features/auth/login_screen.dart';
import 'features/auth/password_reset_confirm_screen.dart';
import 'features/auth/password_reset_request_screen.dart';
import 'features/auth/register_screen.dart';
import 'features/auth/key_backup_screen.dart';
import 'features/auth/restore_key_screen.dart';
import 'features/auth/rotate_key_screen.dart';
import 'features/auth/totp_challenge_screen.dart';
import 'features/auth/totp_enroll_screen.dart';
import 'features/auth/verify_email_screen.dart';
import 'features/billing/paywall_screen.dart';
import 'features/history/transfer_history_screen.dart';
import 'features/home/home_screen.dart';
import 'features/transfers/batch_send_screen.dart';
import 'features/settings/delete_account_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/transfers/inbox_screen.dart';
import 'features/transfers/link_receive_screen.dart';
import 'features/transfers/receive_screen.dart';
import 'features/transfers/send_screen.dart';
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
          path == '/password-reset' ||
          // Link-mode receive is unauthenticated by design (ADR-0010).
          // Signed-out users tapping a share link must be able to
          // land on the receive screen without a login detour.
          path.startsWith('/r/');
      if (!isSignedIn && !atAuthSurface) return '/login';
      if (isSignedIn && (path == '/login' || path == '/register')) return '/';
      return null;
    },
    routes: [
      GoRoute(path: '/', builder: (_, __) => const HomeScreen()),
      GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),
      GoRoute(path: '/register', builder: (_, __) => const RegisterScreen()),
      // Reachable from the fingerprint card on the home screen, which is
      // where the problem surfaces — the card is what says "not
      // available on this device".
      GoRoute(
        path: '/rotate-key',
        builder: (_, __) => const RotateKeyScreen(),
      ),
      GoRoute(
        path: '/key-backup',
        builder: (_, __) => const KeyBackupScreen(),
      ),
      GoRoute(
        path: '/restore-key',
        builder: (_, __) => const RestoreKeyScreen(),
      ),
      GoRoute(
        path: '/settings',
        builder: (_, __) => const SettingsScreen(),
      ),
      GoRoute(
        path: '/settings/delete-account',
        builder: (_, __) => const DeleteAccountScreen(),
      ),
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
      // M2 transfer surface.
      GoRoute(path: '/send', builder: (_, __) => const SendScreen()),
      // Multi-file batch progress + completion (ADR-0009).
      GoRoute(
        path: '/send/batch',
        builder: (_, __) => const BatchSendScreen(),
      ),
      GoRoute(path: '/inbox', builder: (_, __) => const InboxScreen()),
      // M3 billing surface — balance + catalog + IAP verify (stubbed).
      GoRoute(path: '/paywall', builder: (_, __) => const PaywallScreen()),
      // Local transfer history (ADR-0007).
      GoRoute(
        path: '/history',
        builder: (_, __) => const TransferHistoryScreen(),
      ),
      GoRoute(
        path: '/receive/:transferId',
        builder: (context, state) => ReceiveScreen(
          transferId: state.pathParameters['transferId'] ?? '',
        ),
      ),
      // In-app link-mode receive (ADR-0010). Matches the web decrypt
      // page's URL shape (`<origin>/r/<id>#<K_file>`) so a universal
      // link opens either the app or the fallback web page depending
      // on Android verification state. The K_file rides in the URL
      // fragment — never transmitted to the server.
      GoRoute(
        path: '/r/:transferId',
        builder: (context, state) => LinkReceiveScreen(
          transferId: state.pathParameters['transferId'] ?? '',
          fileKeyB64Url: state.uri.fragment,
        ),
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
