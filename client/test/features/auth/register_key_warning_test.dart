// The web key-durability warning on the registration screen.
//
// On web the identity key is generated in the browser and kept in
// browser storage, which is evictable — WebKit clears all
// script-writable storage after seven days of Safari use without
// interaction, and there is no key-rotation endpoint, so the loss is
// permanent and silent. Someone choosing where to register deserves to
// know that before they choose, not after.
//
// The warning is gated on `kIsWeb`, which is a compile-time constant:
// false under `flutter test` (Dart VM), true under
// `flutter test --platform chrome`. So the two branches are genuinely
// only reachable from the two runners, and this file asserts whichever
// one it finds itself in rather than pretending to cover both at once.
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nduzem/features/auth/register_screen.dart';

void main() {
  Future<void> pumpRegister(WidgetTester tester) async {
    // The default 800x600 test surface is shorter than this form once
    // the warning card is added, and a RenderFlex overflow throws.
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: RegisterScreen()),
      ),
    );
    await tester.pump();
  }

  testWidgets('the browser-key warning matches the platform', (tester) async {
    await pumpRegister(tester);

    // Match on the load-bearing claims rather than the full paragraph,
    // so copy edits do not break the test but a deletion does.
    final neverLeaves = find.textContaining('never leaves it');
    final cannotRestore = find.textContaining('cannot');
    final sameBrowser = find.textContaining('same browser');

    if (kIsWeb) {
      expect(
        neverLeaves,
        findsOneWidget,
        reason: 'web users must be told the key is browser-local',
      );
      expect(
        cannotRestore,
        findsWidgets,
        reason: 'web users must be told it cannot be restored',
      );
      expect(
        sameBrowser,
        findsOneWidget,
        reason: 'web users must be told to return to this browser',
      );
    } else {
      // Native keeps the keypair in the Keychain /
      // EncryptedSharedPreferences, which the OS does not evict on an
      // inactivity timer. Showing a browser-storage warning there would
      // be false, and would train users to ignore it where it is true.
      expect(neverLeaves, findsNothing);
      expect(sameBrowser, findsNothing);
    }
  });
}
