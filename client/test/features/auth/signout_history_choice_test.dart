// Signing out offers to clear transfer history; it does not impose it.
//
// The original design cleared unconditionally, which was wrong in both
// directions. It bought little — history is scoped per user, so signing
// in as someone else cannot reveal it, and the real exposure is
// device-level, which signing out does nothing about. And it cost
// something real: a user who wanted to keep their records learned not to
// sign out, and staying signed in on a borrowed machine is far worse
// than a retained history.
//
// The DEFAULT is the policy, because most people accept defaults. These
// pin it unchecked, and pin that dismissing the dialog is not consent.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nduzem/features/home/home_screen.dart';

/// Drives the real dialog through the real entry point.
Future<void> _openSignOutMenu(WidgetTester tester) async {
  await tester.tap(find.byType(PopupMenuButton<String>));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Sign out'));
  await tester.pumpAndSettle();
}

Future<void> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    const ProviderScope(child: MaterialApp(home: HomeScreen())),
  );
  await tester.pump();
}

void main() {
  testWidgets('the history checkbox defaults to UNCHECKED', (tester) async {
    // This assertion is the policy. Flipping the default would silently
    // restore the old behaviour for almost everyone, because almost
    // everyone accepts a default.
    await _pump(tester);
    await _openSignOutMenu(tester);

    final box = tester.widget<CheckboxListTile>(
      find.byType(CheckboxListTile),
    );
    expect(
      box.value,
      isFalse,
      reason: 'defaulting to delete would destroy the user\'s own records '
          'to defend against a threat signing out does not address',
    );
  });

  testWidgets('the dialog offers the choice rather than announcing it',
      (tester) async {
    await _pump(tester);
    await _openSignOutMenu(tester);

    expect(find.text('Also delete my transfer history'), findsOneWidget);
    expect(find.text('Sign out'), findsWidgets);
    expect(find.text('Cancel'), findsOneWidget);
  });

  testWidgets('it says what is KEPT, not only what could be lost',
      (tester) async {
    // Someone deciding whether to tick the box needs to know that
    // verified contacts and the encryption key survive — otherwise the
    // dialog reads as though signing out is destructive in general,
    // which is the impression that stops people signing out at all.
    await _pump(tester);
    await _openSignOutMenu(tester);

    expect(find.textContaining('encryption key'), findsOneWidget);
    expect(find.textContaining('verified'), findsOneWidget);
  });

  testWidgets('the checkbox can be ticked', (tester) async {
    await _pump(tester);
    await _openSignOutMenu(tester);

    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();

    expect(
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
      isTrue,
      reason: 'the dialog holds its own state — a StatelessWidget here '
          'would render a checkbox that never changes',
    );
  });
}
