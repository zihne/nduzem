import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nduzem/crypto/envelope.dart';

import 'sodium_test_support.dart';

/// `blob_sha256` reaches the client from the server and is therefore
/// attacker-controlled. It is hex-decoded before being used as the
/// signed message, so the decoder's notion of "valid hex" is part of the
/// signature check's attack surface.
///
/// The decoder used `int.parse(radix: 16)` per byte pair, which accepts
/// signs and whitespace: `"+1"`, `" 1"` and `"1 "` all yield 1 (the same
/// as `"01"`), and `"-2"` yields -2, which stores into a `Uint8List` as
/// 254. Distinct strings therefore decoded to identical bytes and would
/// verify under the same signature.
Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();

  final maybeSodium = await tryInitSodium();
  final skipReason = sodiumSkipReason(maybeSodium);
  late final Envelope envelope;
  if (maybeSodium != null) envelope = Envelope(maybeSodium);

  // 64 hex chars, the shape of a real SHA-256, with the leading byte
  // swapped for each malformed variant so length stays valid.
  String withLeadingPair(String pair) => pair + ('ab' * 31);

  const wellFormed = '01';

  group(
    'signature-input hex decoding',
    () {
      for (final bad in <String>['+1', '-2', ' 1', '1 ', 'g0', '0g', '\t1']) {
        test('rejects "$bad" as a leading byte', () {
          expect(
            () => envelope.verifyBlobSha256Signature(
              blobSha256Hex: withLeadingPair(bad),
              signature: Uint8List(64),
              senderSigningPublic: Uint8List(32),
            ),
            throwsA(isA<FormatException>()),
            reason: 'non-hex input must be refused, not silently coerced',
          );
        });
      }

      test('two different strings can no longer decode to the same bytes', () {
        // The specific collision the old decoder allowed: "+1" and "01".
        // Both parsed to 1, so a signature over one verified over the other.
        final good = withLeadingPair(wellFormed);
        final collidingUnderOldDecoder = withLeadingPair('+1');
        expect(good, isNot(collidingUnderOldDecoder));
        expect(
          () => envelope.verifyBlobSha256Signature(
            blobSha256Hex: collidingUnderOldDecoder,
            signature: Uint8List(64),
            senderSigningPublic: Uint8List(32),
          ),
          throwsA(isA<FormatException>()),
        );
      });

      test('accepts both upper and lower case hex', () {
        // package:crypto emits lowercase, but nothing in the wire format
        // forbids uppercase and rejecting it would be a new failure mode.
        for (final hex in <String>['ab' * 32, 'AB' * 32, 'aB' * 32]) {
          expect(
            envelope.verifyBlobSha256Signature(
              blobSha256Hex: hex,
              signature: Uint8List(64),
              senderSigningPublic: Uint8List(32),
            ),
            isFalse,
            reason: 'well-formed hex must decode, then fail on the signature',
          );
        }
      });

      test('odd-length input is refused', () {
        expect(
          () => envelope.verifyBlobSha256Signature(
            blobSha256Hex: 'abc',
            signature: Uint8List(64),
            senderSigningPublic: Uint8List(32),
          ),
          throwsA(isA<FormatException>()),
        );
      });
    },
    skip: skipReason,
  );
}
