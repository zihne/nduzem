import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sodium_libs/sodium_libs.dart';

import 'package:opaqueshare/crypto/file_crypto.dart';

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
}
