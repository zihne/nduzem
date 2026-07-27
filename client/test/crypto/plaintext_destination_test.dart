import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:opaqueshare/crypto/plaintext_destination.dart';

/// Unit tests for the ADR-0013 Phase-5 `PlaintextDestination`
/// abstraction. The mobile [FilePlaintextDestination] is the only
/// concrete impl this branch ships; the web variant lands in Phase 6.
void main() {
  group('FilePlaintextDestination', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('opq-plaintext-dest-');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('newTempFile writes each chunk in order and closes cleanly',
        () async {
      final dest = await FilePlaintextDestination.newTempFile(tmp);
      final chunks = <List<int>>[
        List<int>.generate(100, (i) => i & 0xff),
        List<int>.generate(50, (i) => (i * 3) & 0xff),
        List<int>.generate(200, (i) => (i * 7 + 5) & 0xff),
      ];
      for (final c in chunks) {
        await dest.add(c);
      }
      await dest.close();

      final expected = <int>[];
      for (final c in chunks) {
        expected.addAll(c);
      }
      expect(dest.bytesWritten, expected.length);
      final got = await File(dest.path).readAsBytes();
      expect(got, expected);
    });

    test('newTempFile creates the dir if it doesn\'t exist yet', () async {
      final nested = Directory('${tmp.path}/does/not/exist/yet');
      expect(await nested.exists(), isFalse);
      final dest = await FilePlaintextDestination.newTempFile(nested);
      await dest.add(Uint8List.fromList(<int>[1, 2, 3]));
      await dest.close();
      expect(await nested.exists(), isTrue);
      expect(await File(dest.path).exists(), isTrue);
    });

    test('discard removes the partial temp file, safe pre-close', () async {
      final dest = await FilePlaintextDestination.newTempFile(tmp);
      await dest.add(Uint8List.fromList(<int>[1, 2, 3, 4]));
      // No close(); simulate the mid-decrypt cancel path.
      await dest.discard();
      expect(await File(dest.path).exists(), isFalse);
      final leftovers = tmp
          .listSync()
          .where((e) => e.path.endsWith('.dec.tmp'))
          .toList();
      expect(leftovers, isEmpty);
    });

    test('discard after close still deletes the file', () async {
      final dest = await FilePlaintextDestination.newTempFile(tmp);
      await dest.add(Uint8List.fromList(<int>[9, 8, 7]));
      await dest.close();
      expect(await File(dest.path).exists(), isTrue);
      await dest.discard();
      expect(await File(dest.path).exists(), isFalse);
    });

    test('close is idempotent — a second call is a no-op', () async {
      final dest = await FilePlaintextDestination.newTempFile(tmp);
      await dest.add(Uint8List.fromList(<int>[1]));
      await dest.close();
      await dest.close();  // must not throw / must not reopen the sink
      expect(await File(dest.path).exists(), isTrue);
    });
  });

  group('BlobPlaintextDestination', () {
    test('accumulates chunks in order; bytes valid after close', () async {
      final dest = BlobPlaintextDestination();
      final chunks = <List<int>>[
        List<int>.generate(100, (i) => i & 0xff),
        List<int>.generate(50, (i) => (i * 3) & 0xff),
        List<int>.generate(200, (i) => (i * 7 + 5) & 0xff),
      ];
      for (final c in chunks) {
        await dest.add(c);
      }
      final expected = <int>[];
      for (final c in chunks) {
        expected.addAll(c);
      }
      expect(dest.bytesWritten, expected.length);
      await dest.close();
      expect(dest.bytes, expected);
    });

    test('bytes before close throws', () async {
      final dest = BlobPlaintextDestination();
      await dest.add(Uint8List.fromList(<int>[1, 2, 3]));
      expect(() => dest.bytes, throwsStateError);
    });

    test('discard clears the buffer, bytes becomes unreadable', () async {
      final dest = BlobPlaintextDestination();
      await dest.add(Uint8List.fromList(<int>[9, 8, 7]));
      await dest.discard();
      expect(() => dest.bytes, throwsStateError);
    });

    test('close is idempotent', () async {
      final dest = BlobPlaintextDestination();
      await dest.add(Uint8List.fromList(<int>[42]));
      await dest.close();
      await dest.close();
      expect(dest.bytes, <int>[42]);
    });

    test('empty payload roundtrips cleanly', () async {
      final dest = BlobPlaintextDestination();
      await dest.close();
      expect(dest.bytesWritten, 0);
      expect(dest.bytes, isEmpty);
    });
  });
}
