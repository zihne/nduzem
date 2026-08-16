// The verify-email screen must never be a dead end.
//
// It is reached two ways: from registration, and from a deep link in the
// verification email. The deep-link path arrives on a FRESH navigation
// stack — nothing to pop, so Flutter renders no back arrow — and the
// screen's only other controls are "Verify" and "Resend", both of which
// need a 6-digit code the user may not have.
//
// So whenever the token does not carry the user through (expired,
// already consumed, absent because the link was mangled, or the request
// failed), they are stranded on a screen with no exit. That was the
// reported behaviour: the app opened the link, stayed on verify-email,
// and offered no way to reach either the app or sign-in.
//
// These assert the two exits exist. They are cheap, and the bug they
// guard against is invisible in the happy path — verification succeeds,
// `context.go('/')` fires, and nobody notices the screen has no door.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:nduzem/features/auth/verify_email_screen.dart';

Widget _app({String? token, required List<String> visited}) {
  final router = GoRouter(
    initialLocation: '/verify-email',
    routes: [
      GoRoute(
        path: '/',
        builder: (_, __) {
          visited.add('/');
          return const Scaffold(body: Text('LANDED'));
        },
      ),
      GoRoute(
        path: '/verify-email',
        builder: (_, __) => VerifyEmailScreen(
          userId: 'u1',
          email: 'a@example.com',
          token: token,
        ),
      ),
    ],
  );
  return ProviderScope(child: MaterialApp.router(routerConfig: router));
}

void main() {
  Future<void> pump(WidgetTester tester, Widget w) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(w);
    await tester.pump();
  }

  testWidgets('offers a way out even with no token and no history',
      (tester) async {
    // The stranding case: arrived without a usable token, so the
    // auto-verify never runs and there is nothing to react to.
    final visited = <String>[];
    await pump(tester, _app(token: null, visited: visited));

    final exit = find.byIcon(Icons.close);
    expect(
      exit,
      findsOneWidget,
      reason: 'deep links leave no history, so Flutter draws no back arrow — '
          'the screen must supply its own exit',
    );

    await tester.tap(exit);
    await tester.pumpAndSettle();
    expect(visited, contains('/'), reason: 'the exit must actually navigate');
    expect(find.text('LANDED'), findsOneWidget);
  });

  testWidgets('the exit leaves the route rather than trying to pop',
      (tester) async {
    // `pop` on a fresh stack does nothing and would leave the user
    // exactly where they were — the failure this screen already had.
    final visited = <String>[];
    await pump(tester, _app(token: null, visited: visited));

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(find.byType(VerifyEmailScreen), findsNothing);
  });
}
