import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:opaqueshare/crypto/plaintext_source.dart';

/// Unit tests for the ADR-0013 Phase-1 `PlaintextSource` abstraction.
///
/// The behaviour contract these tests lock in:
///
/// - `lengthBytes` matches the actual number of bytes yielded by
///   `openRead()` — the transfer pipeline uses this for the pre-flight
///   `/initiate` call and would over/underclaim quota otherwise.
/// - `filename` / `mimeType` are round-tripped verbatim (they feed
///   directly into `enc_header`).
/// - `openRead()` yields the same bytes as the underlying source, in
///   order, and does not require holding the whole payload in memory
///   in the caller (the stream shape is enforced by the interface;
///   the impls delegate to `File.openRead()` / a chunk loop).
void main() {
  group('FilePlaintextSource', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('opq-plaintext-source-');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('fromPath stats the file and stores metadata', () async {
      final file = File('${tmp.path}/report.pdf');
      final bytes = Uint8List.fromList(List<int>.generate(4321, (i) => i & 0xff));
      await file.writeAsBytes(bytes);

      final source = await FilePlaintextSource.fromPath(
        file.path,
        mimeType: 'application/pdf',
      );

      expect(source.lengthBytes, bytes.length);
      expect(source.filename, 'report.pdf');
      expect(source.mimeType, 'application/pdf');
    });

    test('fromPath defaults filename to the basename', () async {
      final file = File('${tmp.path}/nested/path/data.bin');
      await file.create(recursive: true);
      await file.writeAsBytes(<int>[1, 2, 3]);

      final source = await FilePlaintextSource.fromPath(file.path);
      expect(source.filename, 'data.bin');
      expect(source.mimeType, isNull);
    });

    test('openRead streams the exact file contents', () async {
      final file = File('${tmp.path}/blob.bin');
      final bytes = Uint8List.fromList(
        List<int>.generate(200 * 1024, (i) => (i * 31 + 7) & 0xff),
      );
      await file.writeAsBytes(bytes);

      final source = await FilePlaintextSource.fromPath(file.path);
      final collected = <int>[];
      await for (final chunk in source.openRead()) {
        collected.addAll(chunk);
      }
      expect(collected.length, bytes.length);
      expect(collected, bytes);
    });

    test('openRead on an empty file yields zero bytes', () async {
      final file = File('${tmp.path}/empty.bin');
      await file.writeAsBytes(<int>[]);
      final source = await FilePlaintextSource.fromPath(file.path);
      expect(source.lengthBytes, 0);
      final collected = <int>[];
      await for (final chunk in source.openRead()) {
        collected.addAll(chunk);
      }
      expect(collected, isEmpty);
    });

    test('direct constructor trusts caller-provided length', () {
      // Trust-the-caller variant: the picker already stat'd the file
      // and knows the length; avoid a redundant syscall.
      final source = FilePlaintextSource(
        path: '/tmp/does-not-exist-yet.bin',
        filename: 'x.bin',
        lengthBytes: 999,
        mimeType: 'application/octet-stream',
      );
      expect(source.lengthBytes, 999);
      expect(source.filename, 'x.bin');
      expect(source.mimeType, 'application/octet-stream');
      // openRead is not called here — the point of the direct
      // constructor is that construction doesn't touch the FS.
    });
  });

  group('BytesPlaintextSource', () {
    test('yields the buffer in fixed-size chunks', () async {
      final bytes = Uint8List.fromList(
        List<int>.generate(150, (i) => i),
      );
      final source = BytesPlaintextSource(
        bytes: bytes,
        filename: 'msg.txt',
        mimeType: 'text/plain',
        chunkSize: 64,
      );
      expect(source.lengthBytes, 150);
      expect(source.filename, 'msg.txt');
      expect(source.mimeType, 'text/plain');

      final chunks = <List<int>>[];
      await for (final chunk in source.openRead()) {
        chunks.add(List<int>.from(chunk));
      }
      expect(chunks.length, 3);
      expect(chunks[0].length, 64);
      expect(chunks[1].length, 64);
      expect(chunks[2].length, 22);
      expect(chunks.expand((c) => c).toList(), bytes);
    });

    test('empty payload yields no chunks', () async {
      final source = BytesPlaintextSource(
        bytes: Uint8List(0),
        filename: 'empty.bin',
      );
      expect(source.lengthBytes, 0);
      final chunks = <List<int>>[];
      await for (final chunk in source.openRead()) {
        chunks.add(chunk.toList());
      }
      expect(chunks, isEmpty);
    });

    test('chunk boundary lands on the length exactly', () async {
      // If lengthBytes % chunkSize == 0 there must be NO trailing
      // zero-length chunk — that would confuse the sodium
      // pushChunked which treats a short-final-chunk as the
      // finalization tag.
      final bytes = Uint8List.fromList(List<int>.filled(128, 0x41));
      final source = BytesPlaintextSource(
        bytes: bytes,
        filename: 'aligned.bin',
        chunkSize: 64,
      );
      final chunks = <int>[];
      var chunkCount = 0;
      await for (final chunk in source.openRead()) {
        chunks.addAll(chunk);
        chunkCount++;
      }
      expect(chunkCount, 2);
      expect(chunks, bytes);
    });

  });
}
