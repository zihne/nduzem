// The route from the home screen to account deletion, and the gates on
// the way.
//
// This exists because the capability shipped on the server months
// before any way to reach it shipped on the client, while a public
// policy page told users the path was "account menu → Settings →
// Delete my account". A test that walks that exact path is the thing
// that would have caught it, so that is what these are.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:nduzem/api/users_api.dart';
import 'package:nduzem/features/auth/auth_providers.dart';
import 'package:nduzem/features/auth/auth_repository.dart';
import 'package:nduzem/features/home/home_screen.dart';
import 'package:nduzem/features/settings/delete_account_screen.dart';
import 'package:nduzem/features/settings/settings_screen.dart';

class _StubSession extends AuthNotifier {
  _StubSession(this._session);
  final AuthSession _session;

  @override
  Future<AuthSession?> build() async => _session;
}

Widget _app() {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (_, __) => const HomeScreen()),
      GoRoute(path: '/settings', builder: (_, __) => const SettingsScreen()),
      GoRoute(
        path: '/settings/delete-account',
        builder: (_, __) => const DeleteAccountScreen(),
      ),
      for (final path in ['/restore-key', '/rotate-key', '/key-backup'])
        GoRoute(
          path: path,
          builder: (_, __) => Scaffold(body: Text(path)),
        ),
    ],
  );
  return ProviderScope(
    overrides: [
      authSessionProvider.overrideWith(
        () => _StubSession(
          const AuthSession(
            userId: 'u1',
            email: 'a@example.com',
            handle: 'alice',
            fingerprint: '1234567890123456789012345',
            mfaEnabled: false,
          ),
        ),
      ),
      keyBackupStatusProvider.overrideWith(
        (ref) async => const KeyBackupStatus(exists: true),
      ),
    ],
    child: MaterialApp.router(routerConfig: router),
  );
}

void main() {
  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 3400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
  }

  testWidgets('the published deletion path is walkable end to end',
      (tester) async {
    // Follows account-deletion.html literally: account menu, then
    // Settings, then Delete my account. If any step is renamed or
    // removed, the policy page becomes false and this fails.
    await pump(tester);

    await tester.tap(find.byIcon(Icons.account_circle_outlined));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Delete my account'));
    await tester.pumpAndSettle();

    expect(find.text(erasureConfirmPhrase), findsWidgets);
    expect(find.text('Your password'), findsOneWidget);
  });

  testWidgets('the confirmation phrase must match before anything is sent',
      (tester) async {
    // The password field is the second gate; this is the first. A
    // near-miss must not pass, or the phrase is decoration.
    await pump(tester);
    await tester.tap(find.byIcon(Icons.account_circle_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete my account'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byType(TextFormField).first,
      'erase my account',
    );
    await tester.enterText(find.byType(TextField).last, 'pw');
    await tester.tap(find.widgetWithText(FilledButton, 'Delete my account'));
    await tester.pumpAndSettle();

    // Still on the form, with the phrase called out. Nothing was sent —
    // the repository provider is not even overridden here, so a request
    // would have thrown rather than silently succeeding.
    expect(
      find.textContaining('Type the phrase exactly'),
      findsOneWidget,
    );
  });

  testWidgets('sign out is still reachable from the account menu',
      (tester) async {
    // The account menu replaced a top-level sign-out icon. The body
    // keeps its own sign-out button — the one with the explanation
    // about keys staying on-device — so the claim here is that the
    // menu ADDS an entry rather than that the old one moved.
    await pump(tester);
    expect(find.text('Sign out'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.account_circle_outlined));
    await tester.pumpAndSettle();
    expect(find.text('Sign out'), findsAtLeastNWidgets(2));
  });
}
