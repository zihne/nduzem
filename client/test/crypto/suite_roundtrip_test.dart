import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nduzem/crypto/envelope.dart';
import 'package:nduzem/crypto/file_crypto.dart';
import 'package:nduzem/crypto/suite.dart';
import 'package:nduzem/crypto/suite_keys.dart';
import 'package:sodium_libs/sodium_libs.dart';

import 'sodium_test_support.dart';

/// Whole-envelope round trips per suite.
///
/// The unit tests cover derivation; these cover the thing that actually
/// breaks if dispatch is wrong — header AND body of one envelope, keyed
/// the way the send and receive paths key them. A suite mix-up shows up
/// here as a failure to open, which is exactly how it would present to a
/// user.
Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();

  final maybeSodium = await tryInitSodium();
  final skipReason = sodiumSkipReason(maybeSodium);
  late final Sodium sodium;
  late final FileCrypto fc;
  late final Envelope env;
  if (maybeSodium != null) {
    sodium = maybeSodium;
    fc = FileCrypto(sodium);
    env = Envelope(sodium);
  }

  Uint8List plaintext() => Uint8List.fromList(
        List<int>.generate(
          FileCrypto.plaintextChunkBytes + 777,
          (i) => (i * 17) & 0xff,
        ),
      );

  /// Encrypt header + body exactly as `TransferService.send` does.
  Future<(Uint8List encHeader, Uint8List ciphertext, String hash)> seal(
    Uint8List fileKey,
    CryptoSuite suite,
    Uint8List plain,
  ) async {
    final keys = SuiteKeys.derive(sodium, fileKey, suite);
    final ct = await fc.encryptFile(plaintext: plain, key: keys.bodyKey);
    final hash = fc.sha256Hex(ct);
    final header = env.buildEncHeader(
      filename: 'report.pdf',
      mime: 'application/pdf',
      plaintextLength: plain.length,
      blobSha256Hex: hash,
      fileKey: keys.headerKey,
    );
    return (header, ct, hash);
  }

  group(
    'envelope round trip',
    () {
      for (final suite in CryptoSuite.values) {
        test('suite ${suite.wireValue} opens what it sealed', () async {
          final fileKey = fc.generateFileKey();
          final plain = plaintext();
          final (encHeader, ct, hash) = await seal(fileKey, suite, plain);

          // Receive side: derive from the envelope's own suite.
          final keys = SuiteKeys.derive(sodium, fileKey, suite);
          final header =
              env.openEncHeader(encHeader: encHeader, fileKey: keys.headerKey);
          expect(header.filename, 'report.pdf');
          expect(header.plaintextLength, plain.length);
          expect(header.blobSha256Hex, hash);

          final back =
              await fc.decryptFile(ciphertextBlob: ct, key: keys.bodyKey);
          expect(back, plain);
        });
      }

      test('suite 1 envelopes still open — old transfers keep working', () {
        // The compatibility guarantee. Suite 1 handed K_file to both
        // primitives; anything sent before this build, or in flight
        // across the deploy, must still decrypt.
        final fileKey = fc.generateFileKey();
        final keys = SuiteKeys.derive(sodium, fileKey, CryptoSuite.classical);
        expect(keys.headerKey, fileKey);
        expect(keys.bodyKey, fileKey);
      });

      test('opening a suite-2 header as suite 1 fails', () async {
        // What a dispatch bug looks like. It must fail loudly, not
        // return a header with garbage in it.
        final fileKey = fc.generateFileKey();
        final (encHeader, _, _) =
            await seal(fileKey, CryptoSuite.classicalSplitKeys, plaintext());
        final wrong = SuiteKeys.derive(sodium, fileKey, CryptoSuite.classical);
        expect(
          () => env.openEncHeader(
            encHeader: encHeader,
            fileKey: wrong.headerKey,
          ),
          throwsA(anything),
        );
      });

      test('opening a suite-1 header as suite 2 fails', () async {
        final fileKey = fc.generateFileKey();
        final (encHeader, _, _) =
            await seal(fileKey, CryptoSuite.classical, plaintext());
        final wrong = SuiteKeys.derive(
          sodium,
          fileKey,
          CryptoSuite.classicalSplitKeys,
        );
        expect(
          () => env.openEncHeader(
            encHeader: encHeader,
            fileKey: wrong.headerKey,
          ),
          throwsA(anything),
        );
      });

      test('the header key does not open the body', () async {
        // Domain separation is only real if the two subkeys are not
        // interchangeable.
        final fileKey = fc.generateFileKey();
        final keys = SuiteKeys.derive(
          sodium,
          fileKey,
          CryptoSuite.classicalSplitKeys,
        );
        final ct =
            await fc.encryptFile(plaintext: plaintext(), key: keys.bodyKey);
        await expectLater(
          fc.decryptFile(ciphertextBlob: ct, key: keys.headerKey),
          throwsA(anything),
        );
      });
    },
    skip: skipReason,
  );
}
