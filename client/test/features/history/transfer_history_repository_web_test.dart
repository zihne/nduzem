@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;

import 'package:opaqueshare/features/history/transfer_history_entry.dart';
import 'package:opaqueshare/features/history/transfer_history_repository_web.dart';

/// Smoke tests for the web / localStorage variant of
/// [TransferHistoryRepository]. `@TestOn('browser')` skips these on
/// the default VM `flutter test` run; execute with
/// `flutter test --platform chrome test/features/history` when you
/// want to exercise them.
void main() {
  setUp(() {
    web.window.localStorage.clear();
  });

  SentHistoryEntry sent(String id) => SentHistoryEntry(
        transferId: id,
        timestamp: DateTime.utc(2026, 8, 1),
        filename: '$id.bin',
        sizeBytes: 1234,
        mode: 'app',
        recipientLabel: null,
        maxDownloads: 1,
        hasPassword: false,
      );

  test('log then readAll roundtrips the entry', () async {
    final repo = TransferHistoryRepository(userId: 'u-1');
    await repo.log(sent('t-1'));
    final list = await repo.readAll();
    expect(list, hasLength(1));
    expect(list.first.transferId, 't-1');
  });

  test('per-user scoping — Alice writes do not leak into Bob', () async {
    final alice = TransferHistoryRepository(userId: 'u-alice');
    final bob = TransferHistoryRepository(userId: 'u-bob');
    await alice.log(sent('t-a'));
    expect((await alice.readAll()).map((e) => e.transferId), ['t-a']);
    expect(await bob.readAll(), isEmpty);
  });

  test('no session → reads empty, writes no-op', () async {
    final repo = TransferHistoryRepository(userId: null);
    await repo.log(sent('t-x'));
    expect(await repo.readAll(), isEmpty);
    // Nothing landed in localStorage under any opaqueshare key.
    final keys = <String>[];
    for (var i = 0; i < web.window.localStorage.length; i++) {
      final k = web.window.localStorage.key(i);
      if (k != null) keys.add(k);
    }
    expect(keys.where((k) => k.startsWith('opaqueshare.')), isEmpty);
  });

  test('200-entry cap evicts the oldest', () async {
    final repo = TransferHistoryRepository(userId: 'u-cap');
    for (var i = 0; i < 201; i++) {
      await repo.log(sent('t-$i'));
    }
    final list = await repo.readAll();
    expect(list, hasLength(TransferHistoryRepository.maxEntries));
    // Newest first — the very first insert should have been dropped.
    expect(list.first.transferId, 't-200');
    expect(list.last.transferId, 't-1');
  });

  test('remove drops one entry, leaves the rest', () async {
    final repo = TransferHistoryRepository(userId: 'u-rem');
    await repo.log(sent('t-a'));
    await repo.log(sent('t-b'));
    await repo.log(sent('t-c'));
    await repo.remove('t-b');
    final left = (await repo.readAll()).map((e) => e.transferId).toList();
    expect(left, ['t-c', 't-a']);
  });

  test('clearAll removes the key entirely', () async {
    final repo = TransferHistoryRepository(userId: 'u-clr');
    await repo.log(sent('t-1'));
    await repo.clearAll();
    expect(await repo.readAll(), isEmpty);
    expect(
      web.window.localStorage.getItem('opaqueshare.history.u-clr'),
      isNull,
    );
  });

  test('corrupt payload → readAll returns empty, does not throw', () async {
    web.window.localStorage.setItem(
      'opaqueshare.history.u-bad',
      'this is not json',
    );
    final repo = TransferHistoryRepository(userId: 'u-bad');
    expect(await repo.readAll(), isEmpty);
  });

  test('future schema version → readAll returns empty', () async {
    web.window.localStorage.setItem(
      'opaqueshare.history.u-fut',
      '{"schema_version": 999, "entries": []}',
    );
    final repo = TransferHistoryRepository(userId: 'u-fut');
    expect(await repo.readAll(), isEmpty);
  });
}
