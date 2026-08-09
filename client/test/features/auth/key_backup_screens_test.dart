// UI properties of backup and restore that are behaviour, not styling
// (ADR-0017).
//
// Two of these decide whether the feature works at all:
//   - the recovery key is shown ONCE, so leaving without saving it must
//     be deliberate rather than a reflex tap;
//   - from the no-key state, RESTORE must outrank REPLACE, because one
//     recovers everything already sent and the other abandons it.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:opaqueshare/api/users_api.dart';
import 'package:opaqueshare/features/auth/auth_providers.dart';
import 'package:opaqueshare/features/auth/auth_repository.dart';
import 'package:opaqueshare/features/auth/key_backup_screen.dart';
import 'package:opaqueshare/features/home/home_screen.dart';

class _StubSession extends AuthNotifier {
  _StubSession(this._session);
  final AuthSession _session;

  @override
  Future<AuthSession?> build() async => _session;
}

class _Recorder {
  final pushed = <String>[];
}

Widget _home(
  _Recorder rec, {
  required String fingerprint,
  KeyBackupStatus? backup,
}) {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (_, __) => const HomeScreen()),
      for (final path in ['/restore-key', '/rotate-key', '/key-backup'])
        GoRoute(
          path: path,
          builder: (_, __) {
            rec.pushed.add(path);
            return Scaffold(body: Text(path));
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
      keyBackupStatusProvider.overrideWith((ref) async => backup),
    ],
    child: MaterialApp.router(routerConfig: router),
  );
}

void main() {
  Future<void> pump(WidgetTester tester, Widget w) async {
    tester.view.physicalSize = const Size(1200, 3400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(w);
    await tester.pumpAndSettle();
  }

  group('the no-key state', () {
    testWidgets('offers restore, and ranks it above replacing the key',
        (tester) async {
      // Restore brings the ORIGINAL key back, so everything already
      // sent opens. Replacing abandons all of it. Presenting them as
      // equals — or offering only the destructive one, as the first
      // version of this screen did — invites someone to throw away
      // recoverable mail.
      final rec = _Recorder();
      await pump(tester, _home(rec, fingerprint: ''));

      final restore =
          find.widgetWithText(FilledButton, 'Restore from recovery key');
      final replace = find.widgetWithText(OutlinedButton, 'Replace my key');
      expect(restore, findsOneWidget);
      expect(replace, findsOneWidget);

      // Ranked by position on screen, not merely both present.
      expect(
        tester.getTopLeft(restore).dy,
        lessThan(tester.getTopLeft(replace).dy),
        reason: 'the destructive option is listed first',
      );
    });

    testWidgets('restore navigates to the restore flow', (tester) async {
      final rec = _Recorder();
      await pump(tester, _home(rec, fingerprint: ''));
      final restore =
          find.widgetWithText(FilledButton, 'Restore from recovery key');
      await tester.ensureVisible(restore);
      await tester.tap(restore);
      await tester.pumpAndSettle();
      expect(rec.pushed, ['/restore-key']);
    });
  });

  group('the backup prompt', () {
    testWidgets('appears when we know there is no backup', (tester) async {
      final rec = _Recorder();
      await pump(
        tester,
        _home(
          rec,
          fingerprint: '1' * 25,
          backup: const KeyBackupStatus(exists: false),
        ),
      );
      expect(find.textContaining('not backed up'), findsOneWidget);
      final button = find.widgetWithText(FilledButton, 'Back up my key');
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(rec.pushed, ['/key-backup']);
    });

    testWidgets('stays hidden when a backup already exists', (tester) async {
      final rec = _Recorder();
      await pump(
        tester,
        _home(
          rec,
          fingerprint: '1' * 25,
          backup: const KeyBackupStatus(exists: true),
        ),
      );
      expect(find.textContaining('not backed up'), findsNothing);
    });

    testWidgets('a permanent route exists once a backup is in place',
        (tester) async {
      // Without this there was no entry point at all after the first
      // backup — including for the case that most needs one: losing the
      // recovery key while still holding the device. That is entirely
      // recoverable by making a new backup, and it had no button.
      final rec = _Recorder();
      await pump(
        tester,
        _home(
          rec,
          fingerprint: '1' * 25,
          backup: const KeyBackupStatus(exists: true),
        ),
      );
      expect(find.textContaining('Your key is backed up'), findsOneWidget);

      final again = find.widgetWithText(TextButton, 'Create a new backup…');
      expect(again, findsOneWidget, reason: 'no way to replace a backup');
      await tester.ensureVisible(again);
      await tester.tap(again);
      await tester.pumpAndSettle();
      expect(rec.pushed, ['/key-backup']);
    });

    testWidgets('and it warns that the old recovery key stops working',
        (tester) async {
      // Someone who still has the old key filed away would otherwise
      // keep a key that silently no longer opens anything.
      final rec = _Recorder();
      await pump(
        tester,
        _home(
          rec,
          fingerprint: '1' * 25,
          backup: const KeyBackupStatus(exists: true),
        ),
      );
      expect(find.textContaining('old key stops working'), findsOneWidget);
    });

    testWidgets('stays hidden when the status is unknown', (tester) async {
      // Null means the lookup failed, not that there is no backup.
      // Nagging someone who is already protected whenever the network
      // hiccups teaches them to dismiss the prompt, which costs more
      // than the prompt ever saved.
      final rec = _Recorder();
      await pump(tester, _home(rec, fingerprint: '1' * 25, backup: null));
      expect(find.textContaining('not backed up'), findsNothing);
    });
  });

  group('the backup screen', () {
    testWidgets('says up front that we cannot recover the key for you',
        (tester) async {
      // A user who learns this only after losing the key will
      // reasonably feel misled, and it is much harder to hear then.
      await pump(
        tester,
        const ProviderScope(child: MaterialApp(home: KeyBackupScreen())),
      );
      expect(find.textContaining('cannot reset'), findsOneWidget);
      expect(find.textContaining('permanent'), findsOneWidget);
    });

    testWidgets('explains that the password does not unlock the backup',
        (tester) async {
      // Otherwise asking for it implies the opposite, and the whole
      // reason for a separate recovery key is that the password is NOT
      // what protects this.
      await pump(
        tester,
        const ProviderScope(child: MaterialApp(home: KeyBackupScreen())),
      );
      expect(
        find.textContaining('does not unlock the backup'),
        findsOneWidget,
      );
    });
  });
}
