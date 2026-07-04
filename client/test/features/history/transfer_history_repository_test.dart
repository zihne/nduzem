import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:opaqueshare/features/history/transfer_history_entry.dart';
import 'package:opaqueshare/features/history/transfer_history_repository.dart';

SentHistoryEntry _sent(String id, {DateTime? at}) => SentHistoryEntry(
      transferId: id,
      timestamp: at ?? DateTime.utc(2026, 7, 4, 12),
      filename: '$id.pdf',
      sizeBytes: 4096,
      mode: 'app',
      recipientLabel: 'alice@example.com',
      maxDownloads: 1,
      hasPassword: false,
    );

ReceivedHistoryEntry _received(String id, {DateTime? at}) =>
    ReceivedHistoryEntry(
      transferId: id,
      timestamp: at ?? DateTime.utc(2026, 7, 4, 12),
      filename: '$id.zip',
      sizeBytes: 500 * 1024 * 1024,
      senderIdShort: 'abcd1234',
      senderHandle: '@alice',
      signatureVerified: true,
      savedPath: '/tmp/$id.zip',
    );

void main() {
  late Directory tmp;
  late TransferHistoryRepository repo;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('opq-hist-');
    repo = TransferHistoryRepository(directoryOverride: tmp);
  });

  tearDown(() async {
    if (await tmp.exists()) {
      await tmp.delete(recursive: true);
    }
  });

  test('readAll on a fresh device returns empty', () async {
    final entries = await repo.readAll();
    expect(entries, isEmpty);
  });

  test('log then read round-trips a SentHistoryEntry with all fields',
      () async {
    final entry = SentHistoryEntry(
      transferId: 't-1',
      timestamp: DateTime.utc(2026, 7, 4, 12, 30),
      filename: 'report.pdf',
      sizeBytes: 12345,
      mode: 'link',
      recipientLabel: null,
      maxDownloads: 3,
      hasPassword: true,
    );

    await repo.log(entry);
    final read = await repo.readAll();
    expect(read, hasLength(1));
    final got = read.single as SentHistoryEntry;
    expect(got.transferId, 't-1');
    expect(got.timestamp, entry.timestamp);
    expect(got.filename, 'report.pdf');
    expect(got.sizeBytes, 12345);
    expect(got.mode, 'link');
    expect(got.recipientLabel, isNull);
    expect(got.maxDownloads, 3);
    expect(got.hasPassword, isTrue);
  });

  test('log then read round-trips a ReceivedHistoryEntry', () async {
    final entry = _received('r-1');
    await repo.log(entry);
    final read = await repo.readAll();
    final got = read.single as ReceivedHistoryEntry;
    expect(got.senderHandle, '@alice');
    expect(got.signatureVerified, isTrue);
    expect(got.savedPath, endsWith('r-1.zip'));
  });

  test('most recent entry appears first', () async {
    await repo.log(_sent('old', at: DateTime.utc(2026, 7, 1)));
    await repo.log(_sent('new', at: DateTime.utc(2026, 7, 4)));
    final read = await repo.readAll();
    // `log` prepends, so the last-logged entry sorts to index 0
    // regardless of its wall-clock timestamp. Screens can re-sort by
    // `timestamp` if they need to — the repository preserves
    // insertion order.
    expect(read.first.transferId, 'new');
    expect(read.last.transferId, 'old');
  });

  test('log evicts the oldest entry when we exceed the 200-entry cap',
      () async {
    // Push 201 entries; first log is 'e0', last is 'e200'.
    for (var i = 0; i <= TransferHistoryRepository.maxEntries; i++) {
      await repo.log(_sent('e$i'));
    }
    final read = await repo.readAll();
    expect(read, hasLength(TransferHistoryRepository.maxEntries));
    // 'e0' (the oldest) got evicted; 'e200' (the newest) is at index 0.
    expect(read.first.transferId, 'e200');
    expect(read.any((e) => e.transferId == 'e0'), isFalse);
  });

  test('remove drops one entry by id, leaves the rest', () async {
    await repo.log(_sent('a'));
    await repo.log(_sent('b'));
    await repo.log(_sent('c'));
    await repo.remove('b');
    final read = await repo.readAll();
    expect(read.map((e) => e.transferId).toList(), ['c', 'a']);
  });

  test('clearAll empties the list but leaves a readable file', () async {
    await repo.log(_sent('x'));
    await repo.clearAll();
    final read = await repo.readAll();
    expect(read, isEmpty);
    // File exists and is valid JSON with an empty entries array.
    final f = File('${tmp.path}/transfer_history.json');
    expect(await f.exists(), isTrue);
    final decoded = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    expect(decoded['entries'], isEmpty);
  });

  test('reading a mixed-shape list restores both variants', () async {
    await repo.log(_received('r'));
    await repo.log(_sent('s'));
    final read = await repo.readAll();
    expect(read.first, isA<SentHistoryEntry>());
    expect(read.last, isA<ReceivedHistoryEntry>());
  });

  test('a corrupt file is discarded rather than crashing the app',
      () async {
    // Simulate a torn write / disk corruption. The user shouldn't
    // lose the ability to see NEW history just because the old file
    // is broken.
    final f = File('${tmp.path}/transfer_history.json');
    await f.writeAsString('not valid json{{{');
    final read = await repo.readAll();
    expect(read, isEmpty);
    // Subsequent writes still work.
    await repo.log(_sent('after-corruption'));
    final refreshed = await repo.readAll();
    expect(refreshed.single.transferId, 'after-corruption');
  });

  test('a file from a future schema version is ignored', () async {
    final f = File('${tmp.path}/transfer_history.json');
    await f.writeAsString(
      jsonEncode(<String, dynamic>{
        'schema_version': 999,
        'entries': [_sent('future').toJson()],
      }),
    );
    final read = await repo.readAll();
    expect(read, isEmpty);
  });
}
