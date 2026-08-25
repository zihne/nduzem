// Turning two-factor off must ask for the password, not just a code.
//
// The server requires both, and returns 422 if the password field is
// absent — so a screen that collected only a code would fail every time,
// and only in production. Until August 2026 the endpoint accepted a code
// alone with no rate limit, which meant a stolen session plus ~333k
// guesses removed the second factor in about an hour.
//
// These tests pin the two things that make the screen correct: it asks
// for the password, and it offers the recovery-code path — because
// someone disabling two-factor has usually lost the authenticator, and
// offering only a TOTP field would strand exactly those users.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nduzem/features/auth/disable_mfa_screen.dart';

Future<void> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 2200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    const ProviderScope(
      child: MaterialApp(home: DisableMfaScreen()),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('asks for the account password', (tester) async {
    await _pump(tester);
    expect(
      find.widgetWithText(TextFormField, 'Account password'),
      findsOneWidget,
      reason: 'the server returns 422 without it — a code-only screen '
          'would fail on every submission',
    );
  });

  testWidgets('offers the recovery-code path', (tester) async {
    await _pump(tester);
    expect(find.byType(CheckboxListTile), findsOneWidget);
    expect(find.textContaining('recovery code'), findsWidgets);
  });

  testWidgets('switching to a recovery code relabels and clears the field',
      (tester) async {
    await _pump(tester);

    expect(find.widgetWithText(TextFormField, 'Six-digit code'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Six-digit code'),
      '123456',
    );
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextFormField, 'Recovery code'), findsOneWidget);
    expect(
      find.text('123456'),
      findsNothing,
      reason: 'a six-digit TOTP left in the box would be submitted as a '
          'recovery code and rejected',
    );
  });

  testWidgets('will not submit an empty form', (tester) async {
    await _pump(tester);

    await tester.tap(find.widgetWithText(FilledButton, 'Turn off two-factor'));
    await tester.pumpAndSettle();

    expect(find.text('Enter your password'), findsOneWidget);
    expect(find.text('Enter a code'), findsOneWidget);
  });

  testWidgets('rejects a TOTP that is not six digits', (tester) async {
    await _pump(tester);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Account password'),
      'hunter2',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Six-digit code'),
      '123',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Turn off two-factor'));
    await tester.pumpAndSettle();

    expect(find.text('A TOTP code is six digits'), findsOneWidget);
  });
}
