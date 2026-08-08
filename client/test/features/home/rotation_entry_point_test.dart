// Rotation must be INITIATABLE, not only reachable after disaster.
//
// The first version of the fingerprint card offered "Replace my key"
// only when the fingerprint was absent, reasoning that rotation
// permanently orphans everything already sent and should not sit one tap
// from a healthy account.
//
// That removed the capability instead of gating it, and removed it
// exactly where it matters most: suspected key COMPROMISE — a stolen
// laptop, a device someone else had access to — is a legitimate reason
// to rotate, and in that case the key still works perfectly. There was
// no way to start the flow at all.
//
// The guardrails live on the destination screen (password, second
// factor, explicit acknowledgement of the loss), which is where they
// belong. These tests pin BOTH doors open.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:opaqueshare/features/auth/auth_providers.dart';
import 'package:opaqueshare/features/auth/auth_repository.dart';
import 'package:opaqueshare/features/home/home_screen.dart';

class _StubSession extends AuthNotifier {
  _StubSession(this._session);
  final AuthSession _session;

  @override
  Future<AuthSession?> build() async => _session;
}

/// Records navigations so a tap can be asserted without building the
/// real route, which needs a repository, storage and libsodium.
class _Recorder {
  final pushed = <String>[];
}

Widget _harness(_Recorder rec, {required String fingerprint}) {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (_, __) => const HomeScreen()),
      GoRoute(
        path: '/rotate-key',
        builder: (_, __) {
          rec.pushed.add('/rotate-key');
          return const Scaffold(body: Text('rotate'));
        },
      ),
    ],
  );
  return ProviderScope(
    overrides: [
      authSessionProvider.overrideWith(
        () => _StubSession(
          AuthSession(
            userId: 'u1',
            email: 'a@example.com',
            handle: 'alice',
            fingerprint: fingerprint,
            mfaEnabled: false,
          ),
        ),
      ),
    ],
    child: MaterialApp.router(routerConfig: router),
  );
}

void main() {
  Future<void> pump(WidgetTester tester, Widget w) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(w);
    await tester.pumpAndSettle();
  }

  testWidgets('reachable when the key is MISSING (the recovery case)',
      (tester) async {
    final rec = _Recorder();
    // An empty fingerprint is how the home screen represents "no keypair
    // on this device".
    await pump(tester, _harness(rec, fingerprint: ''));

    final entry = find.widgetWithText(OutlinedButton, 'Replace my key');
    expect(entry, findsOneWidget);
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(rec.pushed, ['/rotate-key']);
  });

  testWidgets('reachable when the key WORKS (the compromise case)',
      (tester) async {
    final rec = _Recorder();
    await pump(tester, _harness(rec, fingerprint: '1' * 25));

    // Present, but as a low-prominence text button rather than an
    // outlined one — available if needed, not a suggested action.
    final entry = find.widgetWithText(TextButton, 'Replace my key…');
    expect(
      entry,
      findsOneWidget,
      reason: 'no way to INITIATE rotation with a working key',
    );
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(rec.pushed, ['/rotate-key']);
  });

  testWidgets('the working-key entry point states the cost', (tester) async {
    // It must not read as a harmless settings toggle.
    final rec = _Recorder();
    await pump(tester, _harness(rec, fingerprint: '1' * 25));
    expect(find.textContaining('will stop opening'), findsOneWidget);
  });
}
