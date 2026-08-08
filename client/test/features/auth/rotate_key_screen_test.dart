// The rotation screen's safety properties.
//
// This screen performs an operation that permanently orphans every
// transfer already sealed to the old key. The copy and the gating are
// the only things standing between a user and doing that by accident,
// so they are behaviour, not decoration.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opaqueshare/features/auth/auth_repository.dart';
import 'package:opaqueshare/features/auth/auth_providers.dart';
import 'package:opaqueshare/features/auth/rotate_key_screen.dart';

Widget _harness({required bool mfaEnabled}) {
  return ProviderScope(
    overrides: [
      authSessionProvider.overrideWith(
        () => _StubSession(
          AuthSession(
            userId: 'u1',
            email: 'a@example.com',
            handle: 'alice',
            fingerprint: '1' * 25,
            mfaEnabled: mfaEnabled,
          ),
        ),
      ),
    ],
    child: const MaterialApp(home: RotateKeyScreen()),
  );
}

class _StubSession extends AuthNotifier {
  _StubSession(this._session);
  final AuthSession _session;

  @override
  Future<AuthSession?> build() async => _session;
}

void main() {
  testWidgets('the action is blocked until the consequence is acknowledged',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_harness(mfaEnabled: false));
    await tester.pumpAndSettle();

    final button = find.widgetWithText(FilledButton, 'Replace my key');
    expect(button, findsOneWidget);
    expect(
      tester.widget<FilledButton>(button).onPressed,
      isNull,
      reason: 'rotation was actionable before the user acknowledged the loss',
    );

    await tester.tap(find.byType(CheckboxListTile).last);
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
  });

  testWidgets('the screen says plainly that nothing is recovered',
      (tester) async {
    // A screen someone reaches while looking for their files must not
    // let them infer that this will bring them back.
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_harness(mfaEnabled: false));
    await tester.pumpAndSettle();

    expect(find.textContaining('does not recover'), findsOneWidget);
    expect(find.textContaining('cannot open files'), findsWidgets);
  });

  testWidgets('no second-factor field when MFA is off', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_harness(mfaEnabled: false));
    await tester.pumpAndSettle();
    expect(find.textContaining('Use a recovery code'), findsNothing);
  });

  testWidgets('the recovery-code option is offered when MFA is on',
      (tester) async {
    // Separate test rather than a second pump in the one above:
    // re-pumping with a different override reuses the element tree and
    // the provider is not rebuilt, so the assertion would pass or fail
    // for reasons unrelated to the widget.
    //
    // The lost-device path is the ORDINARY reason to be on this screen,
    // and a lost device takes the authenticator with it — so this option
    // has to be visible, not buried.
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_harness(mfaEnabled: true));
    await tester.pumpAndSettle();
    expect(find.textContaining('Use a recovery code'), findsOneWidget);
  });
}
