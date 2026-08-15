import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nduzem/crypto/fingerprint.dart';

void main() {
  group('fingerprintOf', () {
    // The same vectors are pinned server-side as FINGERPRINT_VECTORS in
    // backend/tests/unit/test_security.py. The client recomputes the
    // fingerprint from the keys the server returns and REFUSES TO SEND
    // when the two disagree, so a divergence here does not degrade
    // gracefully — it blocks sending. These exist so the two
    // implementations can only move together.
    test('matches the server on filled-byte keys', () {
      final fp = fingerprintOf(
        identityPublic: Uint8List.fromList(List.filled(32, 1)),
        signingPublic: Uint8List.fromList(List.filled(32, 2)),
      );
      expect(fp.display, '67703 47913 57848 05272 88176');
      expect(fp.canonical, '6770347913578480527288176');
    });

    test('matches the server on all-zero keys', () {
      final fp = fingerprintOf(
        identityPublic: Uint8List.fromList(List.filled(32, 0)),
        signingPublic: Uint8List.fromList(List.filled(32, 0)),
      );
      expect(fp.display, '17504 27768 53253 73905 03835');
    });

    test('matches the server on sequential-byte keys', () {
      final fp = fingerprintOf(
        identityPublic: Uint8List.fromList(List<int>.generate(32, (i) => i)),
        signingPublic:
            Uint8List.fromList(List<int>.generate(32, (i) => i + 32)),
      );
      expect(fp.display, '29755 14947 17031 55051 47535');
    });

    test('uses the whole digit space — the leading groups vary', () {
      // The previous derivation masked the digest to 60 bits, but five
      // base-100000 groups address 10^25 and 2^60 < 100000^4, so the
      // first group was ALWAYS '00000' and the second never exceeded
      // '01152'. Roughly 8 of 25 digits were constant: a safety number
      // that read as longer than the entropy it carried.
      // Keys derived by hashing a counter. An arithmetic generator like
      // `(i + j) & 0xff` looks varied but repeats every 256 iterations,
      // capping the distinct keypairs well below the threshold and
      // failing for reasons that have nothing to do with the fingerprint.
      final leading = <String>{};
      final second = <String>{};
      for (var i = 0; i < 500; i++) {
        final seed = Uint8List(4)..buffer.asByteData().setUint32(0, i);
        final fp = fingerprintOf(
          identityPublic: Uint8List.fromList(sha256.convert(seed).bytes),
          signingPublic: Uint8List.fromList(
            sha256.convert([...seed, 0x78]).bytes,
          ),
        );
        final groups = fp.display.split(' ');
        leading.add(groups[0]);
        second.add(groups[1]);
      }
      expect(
        leading.length,
        greaterThan(400),
        reason: 'leading group barely varies — digit space unused',
      );
      expect(
        second.length,
        greaterThan(400),
        reason: 'second group barely varies — digit space unused',
      );
    });

    test('canonical is 25 decimal digits; display is 5 groups of 5', () {
      final fp = fingerprintOf(
        identityPublic: Uint8List.fromList(List.filled(32, 42)),
        signingPublic: Uint8List.fromList(List.filled(32, 84)),
      );
      expect(fp.canonical.length, 25);
      expect(RegExp(r'^\d{25}$').hasMatch(fp.canonical), isTrue);
      expect(fp.display.length, 29); // 25 digits + 4 spaces
      expect(fp.display.split(' '), hasLength(5));
    });

    test('is deterministic for the same inputs', () {
      final id = Uint8List.fromList(List.filled(32, 42));
      final sig = Uint8List.fromList(List.filled(32, 84));
      final a = fingerprintOf(identityPublic: id, signingPublic: sig);
      final b = fingerprintOf(identityPublic: id, signingPublic: sig);
      expect(a, equals(b));
      expect(a.matches(b.canonical), isTrue);
      expect(a.matches(b.display), isTrue);
    });

    test('changes if either key changes', () {
      final id = Uint8List.fromList(List.filled(32, 1));
      final sig = Uint8List.fromList(List.filled(32, 2));
      final base = fingerprintOf(identityPublic: id, signingPublic: sig);

      final idPrime = Uint8List.fromList(List.filled(32, 1))..[0] = 99;
      final flipId = fingerprintOf(
        identityPublic: idPrime,
        signingPublic: sig,
      );
      expect(base.matches(flipId.canonical), isFalse);

      final sigPrime = Uint8List.fromList(List.filled(32, 2))..[0] = 99;
      final flipSig = fingerprintOf(
        identityPublic: id,
        signingPublic: sigPrime,
      );
      expect(base.matches(flipSig.canonical), isFalse);
    });
  });

  group('matches', () {
    test('accepts the display form (spaces) and the canonical form', () {
      final fp = fingerprintOf(
        identityPublic: Uint8List.fromList(List.filled(32, 1)),
        signingPublic: Uint8List.fromList(List.filled(32, 2)),
      );
      expect(fp.matches(fp.canonical), isTrue);
      expect(fp.matches(fp.display), isTrue);
      expect(fp.matches('  ${fp.display}  '), isTrue);
    });

    test('rejects a different length', () {
      final fp = fingerprintOf(
        identityPublic: Uint8List.fromList(List.filled(32, 1)),
        signingPublic: Uint8List.fromList(List.filled(32, 2)),
      );
      expect(fp.matches('12345'), isFalse);
    });
  });

  group('tryParseFingerprint', () {
    test('parses canonical form', () {
      final fp = tryParseFingerprint('1234567890123456789012345');
      expect(fp, isNotNull);
      expect(fp!.canonical, '1234567890123456789012345');
    });

    test('parses display form', () {
      final fp = tryParseFingerprint('12345 67890 12345 67890 12345');
      expect(fp, isNotNull);
      expect(fp!.canonical, '1234567890123456789012345');
    });

    test('rejects wrong length', () {
      expect(tryParseFingerprint('12345'), isNull);
      expect(
        tryParseFingerprint('123456789012345678901234567'),
        isNull,
      );
    });

    test('rejects non-digits', () {
      expect(tryParseFingerprint('1234567890abcdef12345 6789'), isNull);
    });
  });
}
