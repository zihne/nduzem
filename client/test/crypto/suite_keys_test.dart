import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:opaqueshare/crypto/file_crypto.dart';
import 'package:opaqueshare/crypto/suite.dart';
import 'package:opaqueshare/crypto/suite_keys.dart';
import 'package:sodium_libs/sodium_libs.dart';

import 'sodium_test_support.dart';

/// Suite 2 splits K_file into domain-separated subkeys so the body
/// secretstream and the header secretbox never share a key.
Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();

  final maybeSodium = await tryInitSodium();
  final skipReason = sodiumSkipReason(maybeSodium);
  late final Sodium sodium;
  late final FileCrypto fc;
  if (maybeSodium != null) {
    sodium = maybeSodium;
    fc = FileCrypto(sodium);
  }

  Uint8List key() => Uint8List.fromList(List<int>.generate(32, (i) => i * 7));

  group(
    'SuiteKeys',
    () {
      test('suite 1 hands the same key to both primitives', () {
        // Not a nicety — this is what keeps every transfer created
        // before suite 2 readable.
        final k = key();
        final keys = SuiteKeys.derive(sodium, k, CryptoSuite.classical);
        expect(keys.headerKey, k);
        expect(keys.bodyKey, k);
      });

      test('suite 2 derives two different keys, neither the master', () {
        final k = key();
        final keys =
            SuiteKeys.derive(sodium, k, CryptoSuite.classicalSplitKeys);
        expect(
          keys.headerKey,
          isNot(k),
          reason: 'header key must not be K_file',
        );
        expect(keys.bodyKey, isNot(k), reason: 'body key must not be K_file');
        expect(
          keys.headerKey,
          isNot(keys.bodyKey),
          reason: 'the whole point is that these differ',
        );
        expect(keys.headerKey, hasLength(sodium.crypto.secretBox.keyBytes));
        expect(keys.bodyKey, hasLength(sodium.crypto.secretStream.keyBytes));
      });

      test('derivation is deterministic', () {
        // Both sides derive independently from the same K_file, so a
        // non-deterministic KDF would make every transfer undecryptable.
        final a =
            SuiteKeys.derive(sodium, key(), CryptoSuite.classicalSplitKeys);
        final b =
            SuiteKeys.derive(sodium, key(), CryptoSuite.classicalSplitKeys);
        expect(a.headerKey, b.headerKey);
        expect(a.bodyKey, b.bodyKey);
      });

      test('a different K_file gives different subkeys', () {
        final other = Uint8List.fromList(List<int>.generate(32, (i) => i * 11));
        final a =
            SuiteKeys.derive(sodium, key(), CryptoSuite.classicalSplitKeys);
        final b =
            SuiteKeys.derive(sodium, other, CryptoSuite.classicalSplitKeys);
        expect(a.headerKey, isNot(b.headerKey));
        expect(a.bodyKey, isNot(b.bodyKey));
      });

      test('suite 2 body key round-trips a real ciphertext', () async {
        final keys =
            SuiteKeys.derive(sodium, key(), CryptoSuite.classicalSplitKeys);
        final plain = Uint8List.fromList(
          List<int>.generate(
            FileCrypto.plaintextChunkBytes + 1234,
            (i) => (i * 13) & 0xff,
          ),
        );
        final ct = await fc.encryptFile(plaintext: plain, key: keys.bodyKey);
        final back =
            await fc.decryptFile(ciphertextBlob: ct, key: keys.bodyKey);
        expect(back, plain);
      });

      test('a suite-2 ciphertext does not open with the raw K_file', () async {
        // The concrete consequence of getting suite dispatch wrong: if a
        // receiver treats a suite-2 envelope as suite 1 it uses K_file
        // directly and must fail, not silently mis-decrypt.
        final k = key();
        final keys =
            SuiteKeys.derive(sodium, k, CryptoSuite.classicalSplitKeys);
        final plain = Uint8List.fromList(List<int>.filled(4096, 9));
        final ct = await fc.encryptFile(plaintext: plain, key: keys.bodyKey);

        await expectLater(
          fc.decryptFile(ciphertextBlob: ct, key: k),
          throwsA(anything),
        );
      });

      test('the KDF context is exactly the length libsodium requires', () {
        // crypto_kdf_CONTEXTBYTES is 8 and libsodium rejects anything
        // else, so a typo here would fail at runtime on the first send
        // rather than at compile time.
        expect(SuiteKeys.kdfContext.length, sodium.crypto.kdf.contextBytes);
      });
    },
    skip: skipReason,
  );
}
