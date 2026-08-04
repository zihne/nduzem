import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opaqueshare/crypto/temp_sweeper.dart';

/// The sweeper exists because `dispose()` does not run when the process
/// is killed, so a decrypted plaintext can outlive the app in the cache
/// directory. These pin both halves of that: stale plaintext really is
/// removed, and a temp belonging to an in-flight receive is not.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('sweeper-test-');
  });
  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<File> write(String name, {Duration? age}) async {
    final f = File('${dir.path}/$name');
    await f.writeAsString('x');
    if (age != null) {
      await f.setLastModified(DateTime.now().subtract(age));
    }
    return f;
  }

  test('deletes a stale decrypted-plaintext temp', () async {
    final f = await write(
      'opaqueshare-a1b2c3.dec.tmp',
      age: const Duration(hours: 3),
    );
    final n = await sweepStaleTemps(dir);
    expect(n, 1);
    expect(await f.exists(), isFalse);
  });

  test('deletes a stale ciphertext temp too', () async {
    final f = await write(
      'opaqueshare-deadbeef.ct.tmp',
      age: const Duration(hours: 3),
    );
    await sweepStaleTemps(dir);
    expect(await f.exists(), isFalse);
  });

  test('leaves a fresh temp alone — a receive may be using it', () async {
    // The failure this prevents is worse than the leak it fixes:
    // deleting a temp mid-stream breaks a transfer in progress.
    final f = await write('opaqueshare-inflight.dec.tmp');
    final n = await sweepStaleTemps(dir);
    expect(n, 0);
    expect(await f.exists(), isTrue);
  });

  test('never touches files it did not write', () async {
    // Runs against the shared OS temp directory, so anything outside our
    // exact naming scheme must be untouchable.
    final others = <File>[
      await write('important.txt', age: const Duration(days: 9)),
      await write('opaqueshare-notes.txt', age: const Duration(days: 9)),
      await write('other-app-abc.dec.tmp', age: const Duration(days: 9)),
      await write('opaqueshare-.dec.tmp', age: const Duration(days: 9)),
      await write('opaqueshare-abc.dec.tmp.bak', age: const Duration(days: 9)),
    ];
    final n = await sweepStaleTemps(dir);
    expect(n, 0, reason: 'matched something outside our naming scheme');
    for (final f in others) {
      expect(await f.exists(), isTrue, reason: '${f.path} was deleted');
    }
  });

  test('a missing directory is not an error', () async {
    final gone = Directory('${dir.path}/nope');
    expect(await sweepStaleTemps(gone), 0);
  });

  test('sweeps several and reports the count', () async {
    for (var i = 0; i < 4; i++) {
      await write('opaqueshare-f$i.dec.tmp', age: const Duration(hours: 5));
    }
    await write('opaqueshare-keep.dec.tmp');
    expect(await sweepStaleTemps(dir), 4);
  });

  test('the age cutoff is honoured exactly', () async {
    final now = DateTime.now();
    await write('opaqueshare-old.dec.tmp', age: const Duration(minutes: 61));
    await write('opaqueshare-new.dec.tmp', age: const Duration(minutes: 59));
    final n = await sweepStaleTemps(
      dir,
      now: now,
      olderThan: const Duration(hours: 1),
    );
    expect(n, 1);
    expect(File('${dir.path}/opaqueshare-new.dec.tmp').existsSync(), isTrue);
  });
}
