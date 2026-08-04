import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as dart_crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium_libs/sodium_libs.dart';

import 'package:opaqueshare/crypto/file_crypto.dart';
import 'package:opaqueshare/crypto/plaintext_source.dart';
import 'sodium_test_support.dart';

/// M4 ciphertext-format tests (ADR-0003).
///
/// libsodium is loaded via `sodium_libs`, which on Linux hosts needs
/// Flutter's platform-channel binding to be initialized. If the host
/// can't load libsodium (e.g. CI without native artifacts) every
/// test in this group skips with a clear reason rather than
/// silently passing.
// `main` is async so libsodium resolves before the tests are declared:
// `skip:` is evaluated at declaration time, not inside `setUpAll`.
Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();

  final maybeSodium = await tryInitSodium();
  final skipReason = sodiumSkipReason(maybeSodium);

  // Non-nullable and `late`: every test carries `skip: skipReason`, so a
  // body only runs once these are assigned. If that ever stops holding,
  // the failure is a loud LateInitializationError rather than the silent
  // early `return` this replaced — which let 22 crypto tests report
  // PASSED while executing no assertions at all.
  late final Sodium sodium;
  late final FileCrypto fc;
  if (maybeSodium != null) {
    sodium = maybeSodium;
    fc = FileCrypto(sodium);
  }

  test(
    'roundtrip: empty plaintext → OS4S container → same empty bytes',
    () async {
      final key = fc.generateFileKey();
      final ct = await fc.encryptFile(plaintext: Uint8List(0), key: key);
      // Magic prefix + secretstream header (24 bytes) + at least one
      // empty final chunk (17 bytes overhead).
      expect(ct.length, greaterThanOrEqualTo(4 + 24 + 17));
      expect(ct.sublist(0, 4), FileCrypto.magicPrefix);

      final pt = await fc.decryptFile(ciphertextBlob: ct, key: key);
      expect(pt.length, 0);
    },
    skip: skipReason,
  );

  test(
    'roundtrip: small plaintext (< chunk size)',
    () async {
      final key = fc.generateFileKey();
      final plain =
          Uint8List.fromList(List<int>.generate(1024, (i) => i & 0xff));
      final ct = await fc.encryptFile(plaintext: plain, key: key);
      final pt = await fc.decryptFile(ciphertextBlob: ct, key: key);
      expect(pt, plain);
    },
    skip: skipReason,
  );

  test(
    'roundtrip: exactly one chunk boundary',
    () async {
      final key = fc.generateFileKey();
      // Exactly plaintextChunkBytes → forces a boundary condition where
      // the FINAL tag lands on a chunk of full size (or, in some
      // impls, on an empty following chunk). Either way roundtrips.
      final plain = Uint8List.fromList(
        List<int>.generate(FileCrypto.plaintextChunkBytes, (i) => i & 0xff),
      );
      final ct = await fc.encryptFile(plaintext: plain, key: key);
      final pt = await fc.decryptFile(ciphertextBlob: ct, key: key);
      expect(pt, plain);
    },
    skip: skipReason,
  );

  test(
    'roundtrip: multi-chunk plaintext (> 3 chunks)',
    () async {
      final key = fc.generateFileKey();
      final plain = Uint8List.fromList(
        List<int>.generate(
          FileCrypto.plaintextChunkBytes * 3 + 12345,
          (i) => (i * 31) & 0xff,
        ),
      );
      final ct = await fc.encryptFile(plaintext: plain, key: key);
      final pt = await fc.decryptFile(ciphertextBlob: ct, key: key);
      expect(pt.length, plain.length);
      expect(pt, plain);
    },
    skip: skipReason,
  );

  test(
    'decrypt: missing OS4S magic → FormatException',
    () async {
      final key = fc.generateFileKey();
      final bogus = Uint8List.fromList(List<int>.filled(100, 0x42));
      expect(
        () => fc.decryptFile(ciphertextBlob: bogus, key: key),
        throwsA(isA<FormatException>()),
      );
    },
    skip: skipReason,
  );

  test(
    'decrypt: tampered byte inside a chunk → AEAD failure',
    () async {
      final key = fc.generateFileKey();
      final plain = Uint8List.fromList(List<int>.generate(2000, (i) => i));
      final ct = await fc.encryptFile(plaintext: plain, key: key);
      // Flip a byte well past the header — inside the first chunk's
      // ciphertext body. Any byte flip inside the AEAD-protected
      // region invalidates the Poly1305 tag.
      final tampered = Uint8List.fromList(ct);
      tampered[50] ^= 0x01;
      expect(
        () => fc.decryptFile(ciphertextBlob: tampered, key: key),
        throwsA(isA<Exception>()),
      );
    },
    skip: skipReason,
  );

  test(
    'decrypt: wrong key → AEAD failure',
    () async {
      final k1 = fc.generateFileKey();
      final k2 = fc.generateFileKey();
      final plain = Uint8List.fromList(List<int>.generate(500, (i) => i));
      final ct = await fc.encryptFile(plaintext: plain, key: k1);
      expect(
        () => fc.decryptFile(ciphertextBlob: ct, key: k2),
        throwsA(isA<Exception>()),
      );
    },
    skip: skipReason,
  );

  // --- streaming receive (ADR-0013 Phase 5) ------------------------------

  /// Drain a [DecryptStreamHandle] into a single byte buffer + return
  /// the summary. Test helper only — real callers (`TransferService`)
  /// pipe chunks into a [PlaintextDestination] as they arrive.
  Future<(Uint8List, DecryptSummary)> drainDecrypt(
    DecryptStreamHandle h,
  ) async {
    final all = <int>[];
    await for (final chunk in h.stream) {
      all.addAll(chunk);
    }
    final summary = await h.done;
    return (Uint8List.fromList(all), summary);
  }

  test(
    'decryptToStream: multi-chunk ciphertext roundtrips via in-memory encrypt',
    () async {
      final key = fc.generateFileKey();
      // ~3 chunks + tail so we exercise the multi-chunk path.
      final plain = Uint8List.fromList(
        List<int>.generate(
          FileCrypto.plaintextChunkBytes * 3 + 12345,
          (i) => (i * 91 + 7) & 0xff,
        ),
      );
      final ct = await fc.encryptFile(plaintext: plain, key: key);

      int lastDone = -1;
      int lastTotal = -1;
      final handle = fc.decryptToStream(
        ciphertextStream: Stream<List<int>>.value(ct),
        key: key,
        ciphertextTotalBytes: ct.length,
        onProgress: (done, total) {
          lastDone = done;
          lastTotal = total;
        },
      );
      final (gotBytes, summary) = await drainDecrypt(handle);
      expect(gotBytes, plain);
      expect(summary.plaintextLength, plain.length);
      expect(lastTotal, ct.length);
      expect(lastDone, ct.length);
    },
  );

  test(
    'decryptToStream: interop with in-memory encryptFile (same OS4S container)',
    () async {
      final key = fc.generateFileKey();
      final plain = Uint8List.fromList(
        List<int>.generate(2000, (i) => i & 0xff),
      );
      final ct = await fc.encryptFile(plaintext: plain, key: key);
      final handle = fc.decryptToStream(
        ciphertextStream: Stream<List<int>>.value(ct),
        key: key,
      );
      final (gotBytes, _) = await drainDecrypt(handle);
      expect(gotBytes, plain);
    },
  );

  test(
    'decryptToStream: missing OS4S magic surfaces FormatException on drain',
    () async {
      final key = fc.generateFileKey();
      final bogus = Uint8List.fromList(List<int>.filled(200, 0x42));
      final handle = fc.decryptToStream(
        ciphertextStream: Stream<List<int>>.value(bogus),
        key: key,
      );
      await expectLater(
        () async {
          await for (final _ in handle.stream) {}
        }(),
        throwsA(isA<FormatException>()),
      );
      // `done` mirrors the stream error.
      await expectLater(handle.done, throwsA(isA<FormatException>()));
    },
  );

  test(
    'decryptToStream: throwIfCancelled surfaces the cancel error on the stream',
    () async {
      final key = fc.generateFileKey();
      final plain = Uint8List.fromList(
        List<int>.generate(
          FileCrypto.plaintextChunkBytes * 5,
          (i) => i & 0xff,
        ),
      );
      final ct = await fc.encryptFile(plaintext: plain, key: key);
      // Feed the ciphertext in many small chunks so the cancel check
      // fires several times before the stream would otherwise drain.
      Stream<List<int>> feed() async* {
        var offset = 0;
        while (offset < ct.length) {
          final end = (offset + 1024).clamp(0, ct.length);
          yield Uint8List.sublistView(ct, offset, end);
          offset = end;
        }
      }

      var callCount = 0;
      void throwOnThirdCall() {
        callCount++;
        if (callCount >= 3) {
          throw const _TestCancelled();
        }
      }

      final handle = fc.decryptToStream(
        ciphertextStream: feed(),
        key: key,
        throwIfCancelled: throwOnThirdCall,
      );
      await expectLater(
        () async {
          await for (final _ in handle.stream) {}
        }(),
        throwsA(isA<_TestCancelled>()),
      );
      await expectLater(handle.done, throwsA(isA<_TestCancelled>()));
    },
  );

  // ---------------------------------------------------------------------
  // ADR-0013 Phase 2 — FileCrypto.encryptToStream
  // ---------------------------------------------------------------------
  // Uses the same `fc` + `skipReason` closure variables as the
  // temp-file group above; that's why it lives inside the same
  // `main()`. Test helper `drain` is defined per-group.

  group(
    'encryptToStream (ADR-0013)',
    () {
      /// Drain the stream into a single byte buffer + return the
      /// summary once done. Test helper only — real callers (Phase 3)
      /// will process chunks as they arrive without accumulating.
      Future<(Uint8List, EncryptSummary)> drain(EncryptStreamHandle h) async {
        final all = <int>[];
        await for (final chunk in h.stream) {
          all.addAll(chunk);
        }
        final summary = await h.done;
        return (Uint8List.fromList(all), summary);
      }

      test(
        'estimateCiphertextLength matches actual ciphertext length across '
        'sizes (empty / sub-chunk / chunk boundary / multi-chunk + tail)',
        () async {
          // Boundary values: empty, sub-chunk, chunk-1, chunk exact,
          // chunk+1, several chunks + tail. All must match the estimator
          // so /initiate byte_count === actual ciphertext byte_count.
          final sizes = <int>[
            0,
            1,
            1024,
            FileCrypto.plaintextChunkBytes - 1,
            FileCrypto.plaintextChunkBytes,
            FileCrypto.plaintextChunkBytes + 1,
            FileCrypto.plaintextChunkBytes * 3 + 4321,
          ];
          for (final size in sizes) {
            final key = fc.generateFileKey();
            final plain = Uint8List.fromList(
              List<int>.generate(size, (i) => (i * 17 + 5) & 0xff),
            );
            final handle = fc.encryptToStream(
              source: BytesPlaintextSource(
                bytes: plain,
                filename: 'x.bin',
                mimeType: null,
              ),
              key: key,
            );
            final (ciphertext, summary) = await drain(handle);
            final estimated = fc.estimateCiphertextLength(size);
            expect(
              ciphertext.length,
              estimated,
              reason: 'ciphertext length mismatch at plaintext size $size',
            );
            expect(
              summary.ciphertextLength,
              estimated,
              reason: 'summary length mismatch at plaintext size $size',
            );
            expect(
              summary.blobSha256Hex,
              dart_crypto.sha256.convert(ciphertext).toString(),
              reason: 'blob_sha256 mismatch at plaintext size $size',
            );
            // Roundtrip: encrypted stream still decrypts to plaintext.
            final decrypted =
                await fc.decryptFile(ciphertextBlob: ciphertext, key: key);
            expect(decrypted, plain, reason: 'roundtrip fail at size $size');
          }
        },
      );

      test('empty plaintext still roundtrips', () async {
        final tempDir = await Directory.systemTemp.createTemp('opq-stream-mt-');
        try {
          final key = fc.generateFileKey();
          final sourceFile = File('${tempDir.path}/empty.bin')
            ..writeAsBytesSync(<int>[]);

          final handle = fc.encryptToStream(
            source: await FilePlaintextSource.fromPath(sourceFile.path),
            key: key,
          );
          final (ciphertext, summary) = await drain(handle);

          expect(summary.ciphertextLength, ciphertext.length);
          expect(
            summary.blobSha256Hex,
            dart_crypto.sha256.convert(ciphertext).toString(),
          );
          // Decrypt back to zero bytes.
          final decrypted =
              await fc.decryptFile(ciphertextBlob: ciphertext, key: key);
          expect(decrypted, isEmpty);
        } finally {
          if (await tempDir.exists()) await tempDir.delete(recursive: true);
        }
      });

      test('progress fires and ends at 100%', () async {
        final tempDir =
            await Directory.systemTemp.createTemp('opq-stream-prog-');
        try {
          final key = fc.generateFileKey();
          final plain = Uint8List.fromList(
            List<int>.generate(FileCrypto.plaintextChunkBytes * 4, (i) => i),
          );
          final sourceFile = File('${tempDir.path}/plain.bin')
            ..writeAsBytesSync(plain);

          var lastDone = -1;
          var lastTotal = -1;
          final handle = fc.encryptToStream(
            source: await FilePlaintextSource.fromPath(sourceFile.path),
            key: key,
            onProgress: (done, total) {
              lastDone = done;
              lastTotal = total;
            },
          );
          await drain(handle);

          expect(lastTotal, plain.length);
          expect(lastDone, plain.length);
        } finally {
          if (await tempDir.exists()) await tempDir.delete(recursive: true);
        }
      });

      test(
        'cancel mid-stream throws on the stream AND errors the `done` future',
        () async {
          final tempDir =
              await Directory.systemTemp.createTemp('opq-stream-cx-');
          try {
            final key = fc.generateFileKey();
            final plain = Uint8List.fromList(
              List<int>.generate(
                FileCrypto.plaintextChunkBytes * 5,
                (i) => i & 0xff,
              ),
            );
            final sourceFile = File('${tempDir.path}/plain.bin')
              ..writeAsBytesSync(plain);

            var callCount = 0;
            void cancelOnThirdCheck() {
              callCount++;
              if (callCount >= 3) throw const _TestCancelled();
            }

            final handle = fc.encryptToStream(
              source: await FilePlaintextSource.fromPath(sourceFile.path),
              key: key,
              throwIfCancelled: cancelOnThirdCheck,
            );

            // Stream errors when the cancel check throws.
            await expectLater(
              handle.stream.toList(),
              throwsA(isA<_TestCancelled>()),
            );
            // `done` mirrors the same error (test the caller's
            // side-channel invariant).
            await expectLater(
              handle.done,
              throwsA(isA<_TestCancelled>()),
            );
          } finally {
            if (await tempDir.exists()) await tempDir.delete(recursive: true);
          }
        },
      );

      test('summary is only valid AFTER stream drains (contract check)',
          () async {
        final tempDir = await Directory.systemTemp.createTemp('opq-stream-sd-');
        try {
          final key = fc.generateFileKey();
          final plain = Uint8List.fromList(List<int>.filled(1024, 0x41));
          final sourceFile = File('${tempDir.path}/plain.bin')
            ..writeAsBytesSync(plain);

          final handle = fc.encryptToStream(
            source: await FilePlaintextSource.fromPath(sourceFile.path),
            key: key,
          );

          // Before drain: done is unresolved.
          var resolved = false;
          // ignore: unawaited_futures
          handle.done.then((_) => resolved = true);
          // Yield one microtask so any accidental sync completion
          // could fire — none should.
          await Future<void>.value();
          expect(resolved, isFalse);

          // Drain. Now done resolves with a valid summary.
          await handle.stream.toList();
          final summary = await handle.done;
          expect(summary.ciphertextLength, greaterThan(plain.length));
          expect(summary.blobSha256Hex, hasLength(64));
        } finally {
          if (await tempDir.exists()) await tempDir.delete(recursive: true);
        }
      });
    },
    skip: skipReason,
  );
}

class _TestCancelled implements Exception {
  const _TestCancelled();
}
