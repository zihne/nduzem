// The transfer-details dialog overflowed on small phones.
//
// It set `content: SizedBox(width: 400)` and handed AlertDialog a bare
// Column. AlertDialog does not scroll `content` unless `scrollable: true`,
// so on a 6" device the rows consumed the available height and the
// Remove button was drawn on top of the Close action. The fixed 400pt
// width did the same thing horizontally, and Row + Spacer overflowed
// rather than reflowing.
//
// Flutter throws on RenderFlex overflow in tests, so pumping the dialog
// at phone sizes is itself the assertion. 320x568 is the narrowest
// commonly-supported viewport; 360x640 is a typical 6" device.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nduzem/features/history/transfer_history_entry.dart';
import 'package:nduzem/features/history/transfer_history_screen.dart';

/// A sent entry with every optional row populated — the tallest the
/// dialog gets, and therefore the case that overflows first.
final _entry = SentHistoryEntry(
  transferId: '11111111-2222-3333-4444-555555555555',
  timestamp: DateTime.utc(2026, 8, 19, 9, 30),
  filename: 'Tenancy-agreement-final-signed.pdf',
  sizeBytes: 4823400,
  mode: 'link',
  recipientLabel: 'someone.with.a.long.address@example.com',
  maxDownloads: 3,
  hasPassword: true,
);

Future<void> _pumpAt(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showTransferDetailDialog(context, _entry),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  for (final (label, size) in <(String, Size)>[
    ('320x568 — narrowest supported', Size(320, 568)),
    ('360x640 — typical 6" phone', Size(360, 640)),
    ('412x915 — large phone', Size(412, 915)),
  ]) {
    testWidgets('lays out without overflow at $label', (tester) async {
      await _pumpAt(tester, size);

      // Reaching here at all means no RenderFlex overflow was thrown.
      expect(find.text('Transfer details'), findsOneWidget);

      // Both actions must remain present and distinct — the reported bug
      // was Remove being drawn over Close, which leaves both findable but
      // overlapping, so also assert they do not intersect.
      final remove = tester.getRect(find.text('Remove'));
      final close = tester.getRect(find.text('Close'));
      expect(
        remove.overlaps(close),
        isFalse,
        reason: 'Remove is drawn over Close at $label — the dialog content '
            'is overflowing into the actions row again',
      );
    });
  }

  testWidgets('content scrolls rather than clipping when it cannot fit',
      (tester) async {
    // A short viewport forces the scroll path. Without `scrollable: true`
    // this throws an overflow instead.
    await _pumpAt(tester, const Size(360, 420));
    expect(find.byType(Scrollable), findsWidgets);
    expect(find.text('Transfer details'), findsOneWidget);
  });
}
