// Known-answer vector for SuiteKeys, shared with the web decrypt page.
//
// `backend/app/static/decrypt.js` is a second, hand-written
// implementation of this derivation — it runs for every recipient who
// opens a link in a browser instead of the app. The two drifted once
// already: the sender moved to suite 2 while the page kept opening
// envelopes with the raw fragment key, so every new link failed with
// "wrong secret key for the given ciphertext".
//
// The constants below are pinned identically in
// backend/tests/js/decrypt_container.test.mjs. Changing the KDF context,
// either subkey id, or a subkey length breaks BOTH suites — which is the
// point. A round-trip test on one side alone would have stayed green
// through the outage, because each implementation was self-consistent.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nduzem/crypto/suite.dart';
import 'package:nduzem/crypto/suite_keys.dart';
import 'package:sodium_libs/sodium_libs.dart';

import 'sodium_test_support.dart';

const _katHeaderKey =
    '18359ed9c33d9f08e5879f851c98e05db7dd879afb37816a0d8776c46ed722c9';
const _katBodyKey =
    'a35845ea389af65350c6cfd2bd69caa8d28a925e6530519b39be4763f8b11823';

String _hex(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();

  final maybeSodium = await tryInitSodium();
  final skipReason = sodiumSkipReason(maybeSodium);
  late final Sodium sodium;
  if (maybeSodium != null) sodium = maybeSodium;

  // K_file = 00 01 02 … 1f
  Uint8List fileKey() => Uint8List.fromList(List<int>.generate(32, (i) => i));

  group(
    'SuiteKeys known-answer vector',
    () {
      test('suite 2 matches the web decrypt page byte for byte', () {
        final keys = SuiteKeys.derive(
          sodium,
          fileKey(),
          CryptoSuite.classicalSplitKeys,
        );
        expect(_hex(keys.headerKey), _katHeaderKey);
        expect(_hex(keys.bodyKey), _katBodyKey);
      });

      test('suite 2 subkeys differ from each other and from K_file', () {
        // Suite 2's entire purpose. If any of these coincide the split
        // is cosmetic.
        final k = fileKey();
        final keys = SuiteKeys.derive(
          sodium,
          k,
          CryptoSuite.classicalSplitKeys,
        );
        expect(_hex(keys.headerKey), isNot(_hex(keys.bodyKey)));
        expect(_hex(keys.headerKey), isNot(_hex(k)));
        expect(_hex(keys.bodyKey), isNot(_hex(k)));
      });

      test('suite 1 passes K_file through unchanged', () {
        final k = fileKey();
        final keys = SuiteKeys.derive(sodium, k, CryptoSuite.classical);
        expect(_hex(keys.headerKey), _hex(k));
        expect(_hex(keys.bodyKey), _hex(k));
      });
    },
    skip: skipReason,
  );
}
