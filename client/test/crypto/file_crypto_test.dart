import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as dart_crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium_libs/sodium_libs.dart';

import 'package:opaqueshare/crypto/file_crypto.dart';
import 'package:opaqueshare/crypto/plaintext_source.dart';

/// M4 ciphertext-format tests (ADR-0003).
///
/// libsodium is loaded via `sodium_libs`, which on Linux hosts needs
/// Flutter's platform-channel binding to be initialized. If the host
/// can't load libsodium (e.g. CI without native artifacts) every
/// test in this group skips with a clear reason rather than
/// silently passing.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  FileCrypto? fc;
  String? skipReason;

  setUpAll(() async {
    try {
      final sodium = await SodiumInit.init();
      fc = FileCrypto(sodium);
    } on Object catch (exc) {
      skipReason = 'libsodium unavailable in this test host: $exc';
    }
  });

  test('roundtrip: empty plaintext → OS4S container → same empty bytes',
      () async {
    if (skipReason != null) return;
    final key = fc!.generateFileKey();
    final ct = await fc!.encryptFile(plaintext: Uint8List(0), key: key);
    // Magic prefix + secretstream header (24 bytes) + at least one
    // empty final chunk (17 bytes overhead).
    expect(ct.length, greaterThanOrEqualTo(4 + 24 + 17));
    expect(ct.sublist(0, 4), FileCrypto.magicPrefix);

    final pt = await fc!.decryptFile(ciphertextBlob: ct, key: key);
    expect(pt.length, 0);
  });

  test('roundtrip: small plaintext (< chunk size)', () async {
    if (skipReason != null) return;
    final key = fc!.generateFileKey();
    final plain = Uint8List.fromList(List<int>.generate(1024, (i) => i & 0xff));
    final ct = await fc!.encryptFile(plaintext: plain, key: key);
    final pt = await fc!.decryptFile(ciphertextBlob: ct, key: key);
    expect(pt, plain);
  });

  test('roundtrip: exactly one chunk boundary', () async {
    if (skipReason != null) return;
    final key = fc!.generateFileKey();
    // Exactly plaintextChunkBytes → forces a boundary condition where
    // the FINAL tag lands on a chunk of full size (or, in some
    // impls, on an empty following chunk). Either way roundtrips.
    final plain = Uint8List.fromList(
      List<int>.generate(FileCrypto.plaintextChunkBytes, (i) => i & 0xff),
    );
    final ct = await fc!.encryptFile(plaintext: plain, key: key);
    final pt = await fc!.decryptFile(ciphertextBlob: ct, key: key);
    expect(pt, plain);
  });

  test('roundtrip: multi-chunk plaintext (> 3 chunks)', () async {
    if (skipReason != null) return;
    final key = fc!.generateFileKey();
    final plain = Uint8List.fromList(
      List<int>.generate(
        FileCrypto.plaintextChunkBytes * 3 + 12345,
        (i) => (i * 31) & 0xff,
      ),
    );
    final ct = await fc!.encryptFile(plaintext: plain, key: key);
    final pt = await fc!.decryptFile(ciphertextBlob: ct, key: key);
    expect(pt.length, plain.length);
    expect(pt, plain);
  });

  test('decrypt: missing OS4S magic → FormatException', () async {
    if (skipReason != null) return;
    final key = fc!.generateFileKey();
    final bogus = Uint8List.fromList(List<int>.filled(100, 0x42));
    expect(
      () => fc!.decryptFile(ciphertextBlob: bogus, key: key),
      throwsA(isA<FormatException>()),
    );
  });

  test('decrypt: tampered byte inside a chunk → AEAD failure', () async {
    if (skipReason != null) return;
    final key = fc!.generateFileKey();
    final plain = Uint8List.fromList(List<int>.generate(2000, (i) => i));
    final ct = await fc!.encryptFile(plaintext: plain, key: key);
    // Flip a byte well past the header — inside the first chunk's
    // ciphertext body. Any byte flip inside the AEAD-protected
    // region invalidates the Poly1305 tag.
    final tampered = Uint8List.fromList(ct);
    tampered[50] ^= 0x01;
    expect(
      () => fc!.decryptFile(ciphertextBlob: tampered, key: key),
      throwsA(isA<Exception>()),
    );
  });

  test('decrypt: wrong key → AEAD failure', () async {
    if (skipReason != null) return;
    final k1 = fc!.generateFileKey();
    final k2 = fc!.generateFileKey();
    final plain = Uint8List.fromList(List<int>.generate(500, (i) => i));
    final ct = await fc!.encryptFile(plaintext: plain, key: k1);
    expect(
      () => fc!.decryptFile(ciphertextBlob: ct, key: k2),
      throwsA(isA<Exception>()),
    );
  });

  // --- streaming send from disk (ADR-0004) --------------------------------

  test(
    'encryptFileToTempFile: multi-chunk file roundtrips via in-memory decrypt',
    () async {
      if (skipReason != null) return;
      final tempDir = await Directory.systemTemp.createTemp('opq-test-');
      try {
        final key = fc!.generateFileKey();
        // ~3 chunks + tail so we exercise the multi-chunk path.
        final plain = Uint8List.fromList(
          List<int>.generate(
            FileCrypto.plaintextChunkBytes * 3 + 7777,
            (i) => (i * 17 + 3) & 0xff,
          ),
        );
        final source = File('${tempDir.path}/source.bin');
        await source.writeAsBytes(plain);

        int lastDone = -1;
        int lastTotal = -1;
        final result = await fc!.encryptFileToTempFile(
          source: await FilePlaintextSource.fromPath(source.path),
          key: key,
          tempDir: tempDir,
          onProgress: (done, total) {
            lastDone = done;
            lastTotal = total;
          },
        );

        // Progress fired and ended at 100 %.
        expect(lastTotal, plain.length);
        expect(lastDone, plain.length);

        // Blob SHA-256 matches sha256(ciphertext file).
        final ct = await File(result.ciphertextPath).readAsBytes();
        expect(ct.length, result.ciphertextLength);
        expect(
          dart_crypto.sha256.convert(ct).toString(),
          result.blobSha256Hex,
        );

        // The ciphertext is a valid OS4S container — the in-memory
        // decrypt reads it back byte-for-byte to the original plaintext.
        final decrypted =
            await fc!.decryptFile(ciphertextBlob: ct, key: key);
        expect(decrypted, plain);
      } finally {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      }
    },
  );

  test(
    'encryptFileToTempFile: cancel mid-encrypt deletes the partial temp file',
    () async {
      if (skipReason != null) return;
      final tempDir = await Directory.systemTemp.createTemp('opq-test-');
      try {
        final key = fc!.generateFileKey();
        final plain = Uint8List.fromList(
          List<int>.generate(
            FileCrypto.plaintextChunkBytes * 5,
            (i) => i & 0xff,
          ),
        );
        final source = File('${tempDir.path}/source.bin');
        await source.writeAsBytes(plain);

        var callCount = 0;
        void throwOnThirdCall() {
          callCount++;
          if (callCount >= 3) {
            throw const _TestCancelled();
          }
        }

        await expectLater(
          fc!.encryptFileToTempFile(
            source: await FilePlaintextSource.fromPath(source.path),
            key: key,
            tempDir: tempDir,
            throwIfCancelled: throwOnThirdCall,
          ),
          throwsA(isA<_TestCancelled>()),
        );

        // Cleanup contract: no `.enc.tmp` files left behind after
        // a mid-encrypt failure.
        final leftovers = tempDir
            .listSync()
            .where((e) => e.path.endsWith('.enc.tmp'))
            .toList();
        expect(leftovers, isEmpty);
      } finally {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      }
    },
  );

  test('encryptFileToTempFile: empty plaintext file still roundtrips',
      () async {
    if (skipReason != null) return;
    final tempDir = await Directory.systemTemp.createTemp('opq-test-');
    try {
      final key = fc!.generateFileKey();
      final source = File('${tempDir.path}/source.bin');
      await source.writeAsBytes(<int>[]);

      final result = await fc!.encryptFileToTempFile(
        source: await FilePlaintextSource.fromPath(source.path),
        key: key,
        tempDir: tempDir,
      );
      final ct = await File(result.ciphertextPath).readAsBytes();
      final decrypted = await fc!.decryptFile(ciphertextBlob: ct, key: key);
      expect(decrypted.length, 0);
    } finally {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    }
  });

  // --- streaming receive (ADR-0006) --------------------------------------

  test(
    'decryptFileToTempFile: multi-chunk file roundtrips via streaming encrypt',
    () async {
      if (skipReason != null) return;
      final tempDir = await Directory.systemTemp.createTemp('opq-test-');
      try {
        final key = fc!.generateFileKey();
        // ~3 chunks + tail so we exercise the multi-chunk path.
        final plain = Uint8List.fromList(
          List<int>.generate(
            FileCrypto.plaintextChunkBytes * 3 + 12345,
            (i) => (i * 91 + 7) & 0xff,
          ),
        );
        final source = File('${tempDir.path}/source.bin');
        await source.writeAsBytes(plain);

        final enc = await fc!.encryptFileToTempFile(
          source: await FilePlaintextSource.fromPath(source.path),
          key: key,
          tempDir: tempDir,
        );

        int lastDone = -1;
        int lastTotal = -1;
        final dec = await fc!.decryptFileToTempFile(
          ciphertextPath: enc.ciphertextPath,
          key: key,
          tempDir: tempDir,
          onProgress: (done, total) {
            lastDone = done;
            lastTotal = total;
          },
        );

        expect(dec.plaintextLength, plain.length);
        expect(lastTotal, enc.ciphertextLength);
        expect(lastDone, enc.ciphertextLength);

        final gotBytes = await File(dec.plaintextPath).readAsBytes();
        expect(gotBytes, plain);
      } finally {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      }
    },
  );

  test(
    'decryptFileToTempFile: interop with in-memory encryptFile (both formats compatible)',
    () async {
      if (skipReason != null) return;
      final tempDir = await Directory.systemTemp.createTemp('opq-test-');
      try {
        final key = fc!.generateFileKey();
        final plain = Uint8List.fromList(
          List<int>.generate(2000, (i) => i & 0xff),
        );
        // Encrypt in memory (the older path), write ciphertext to
        // disk, then stream-decrypt. The streaming decrypt must
        // accept the same OS4S container the in-memory encrypt
        // produces.
        final ct = await fc!.encryptFile(plaintext: plain, key: key);
        final ctFile = File('${tempDir.path}/ct.bin');
        await ctFile.writeAsBytes(ct);

        final dec = await fc!.decryptFileToTempFile(
          ciphertextPath: ctFile.path,
          key: key,
          tempDir: tempDir,
        );

        final gotBytes = await File(dec.plaintextPath).readAsBytes();
        expect(gotBytes, plain);
      } finally {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      }
    },
  );

  test(
    'decryptFileToTempFile: missing OS4S magic surfaces FormatException + cleans temp',
    () async {
      if (skipReason != null) return;
      final tempDir = await Directory.systemTemp.createTemp('opq-test-');
      try {
        final key = fc!.generateFileKey();
        // Non-OS4S bytes.
        final bogus = File('${tempDir.path}/bogus.bin');
        await bogus.writeAsBytes(
          Uint8List.fromList(List<int>.filled(200, 0x42)),
        );

        await expectLater(
          fc!.decryptFileToTempFile(
            ciphertextPath: bogus.path,
            key: key,
            tempDir: tempDir,
          ),
          throwsA(isA<FormatException>()),
        );

        final leftovers = tempDir
            .listSync()
            .where((e) => e.path.endsWith('.dec.tmp'))
            .toList();
        expect(leftovers, isEmpty);
      } finally {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      }
    },
  );

  test(
    'decryptFileToTempFile: cancel mid-decrypt deletes the partial temp file',
    () async {
      if (skipReason != null) return;
      final tempDir = await Directory.systemTemp.createTemp('opq-test-');
      try {
        final key = fc!.generateFileKey();
        final plain = Uint8List.fromList(
          List<int>.generate(
            FileCrypto.plaintextChunkBytes * 5,
            (i) => i & 0xff,
          ),
        );
        final source = File('${tempDir.path}/source.bin');
        await source.writeAsBytes(plain);
        final enc = await fc!.encryptFileToTempFile(
          source: await FilePlaintextSource.fromPath(source.path),
          key: key,
          tempDir: tempDir,
        );

        var callCount = 0;
        void throwOnThirdCall() {
          callCount++;
          if (callCount >= 3) {
            throw const _TestCancelled();
          }
        }

        await expectLater(
          fc!.decryptFileToTempFile(
            ciphertextPath: enc.ciphertextPath,
            key: key,
            tempDir: tempDir,
            throwIfCancelled: throwOnThirdCall,
          ),
          throwsA(isA<_TestCancelled>()),
        );

        final leftovers = tempDir
            .listSync()
            .where((e) => e.path.endsWith('.dec.tmp'))
            .toList();
        expect(leftovers, isEmpty);
      } finally {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      }
    },
  );
}

class _TestCancelled implements Exception {
  const _TestCancelled();
}
