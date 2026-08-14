// The legal documents have to be reachable from inside the app.
//
// Google Play's User Data policy expects the privacy policy to be
// reachable from the app itself, not only from the store listing. Our
// terms also open with "by creating an account you agree to them" —
// which was true of the document and false of the product: for a long
// time the app referenced neither document anywhere in `lib/`.
//
// These assert the URLs actually resolve against the configured
// marketing origin. That matters more than it looks: the first version
// of this code shipped `'/\$file'` with an escaped dollar, so every
// link pointed at the literal path `/$file`. It analysed clean, and
// only a test that reads the resolved URL catches it.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:opaqueshare/api/users_api.dart';
import 'package:opaqueshare/core/config.dart';
import 'package:opaqueshare/features/auth/auth_providers.dart';
import 'package:opaqueshare/features/auth/auth_repository.dart';
import 'package:opaqueshare/features/auth/register_screen.dart';
import 'package:opaqueshare/features/settings/settings_screen.dart';

class _StubSession extends AuthNotifier {
  _StubSession(this._session);
  final AuthSession? _session;

  @override
  Future<AuthSession?> build() async => _session;
}

final _config = AppConfig(
  apiBaseUrl: Uri.parse('https://api.opaqueshare.com'),
  shareUrlBase: Uri.parse('https://opaqueshare.com'),
);

Widget _wrap(Widget child, {AuthSession? session}) => ProviderScope(
      overrides: [
        appConfigProvider.overrideWithValue(_config),
        authSessionProvider.overrideWith(() => _StubSession(session)),
        keyBackupStatusProvider.overrideWith(
          (ref) async => const KeyBackupStatus(exists: true),
        ),
      ],
      child: MaterialApp.router(
        routerConfig: GoRouter(
          initialLocation: '/',
          routes: [GoRoute(path: '/', builder: (_, __) => child)],
        ),
      ),
    );

void main() {
  Future<void> pump(WidgetTester tester, Widget w) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(w);
    await tester.pumpAndSettle();
  }

  group('Settings → About & legal', () {
    testWidgets('lists all three documents', (tester) async {
      await pump(
        tester,
        _wrap(
          const SettingsScreen(),
          session: const AuthSession(
            userId: 'u1',
            email: 'a@example.com',
            handle: 'alice',
            fingerprint: '1234567890123456789012345',
            mfaEnabled: false,
          ),
        ),
      );

      expect(find.text('Privacy Policy'), findsOneWidget);
      expect(find.text('Terms of Service'), findsOneWidget);
      expect(find.text('Account deletion'), findsOneWidget);
    });
  });

  group('the resolved URLs', () {
    // Calls the PRODUCTION helper, not a copy of it. An earlier
    // version of this test re-implemented the construction here and
    // therefore passed while the real screens built a broken URL —
    // a mutation that inlined the bug into settings_screen.dart
    // survived, which is how the flaw was found.
    Uri resolve(String file) => _config.legalPage(file);

    test('point at the marketing origin, not the API origin', () {
      expect(resolve('privacy.html').host, 'opaqueshare.com');
      expect(resolve('privacy.html').host, isNot(startsWith('api.')));
    });

    test('interpolate the filename rather than emitting it literally', () {
      // The exact bug that shipped: `'/\$file'` produces `/$file`.
      final uri = resolve('terms.html');
      expect(uri.path, '/terms.html');
      expect(uri.toString(), 'https://opaqueshare.com/terms.html');
      expect(uri.toString(), isNot(contains(r'$')));
    });

    test('cover every document the pages actually serve', () {
      for (final f in ['privacy.html', 'terms.html', 'account-deletion.html']) {
        expect(resolve(f).toString(), 'https://opaqueshare.com/$f');
      }
    });
  });

  group('registration', () {
    testWidgets('states the agreement and names both documents',
        (tester) async {
      await pump(tester, _wrap(const RegisterScreen()));

      expect(
        find.textContaining('By creating an account you agree'),
        findsOneWidget,
        reason: 'the terms assert this agreement; the screen must too',
      );
      // Named inside the same rich-text span, so `findsOneWidget` on the
      // whole sentence is the assertion — these confirm the document
      // names survive any rewording of the surrounding copy.
      final notice = tester.widget<Text>(
        find.textContaining('By creating an account you agree'),
      );
      final text = notice.textSpan!.toPlainText();
      expect(text, contains('Terms of Service'));
      expect(text, contains('Privacy Policy'));
    });
  });
}
