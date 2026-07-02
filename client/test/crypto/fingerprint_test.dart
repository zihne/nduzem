import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:opaqueshare/crypto/fingerprint.dart';

void main() {
  group('fingerprintOf', () {
    test(
      'matches the server-side algorithm on a known input',
      () {
        // Cross-checked against
        //   `python -c "from app.core.security import key_fingerprint; \
        //     print(key_fingerprint(bytes([1]*32), bytes([2]*32)))"`
        // on the backend. If either side changes the algorithm, this
        // test breaks — good.
        final fp = fingerprintOf(
          identityPublic: Uint8List.fromList(List.filled(32, 1)),
          signingPublic: Uint8List.fromList(List.filled(32, 2)),
        );
        const serverDisplay = '00000 00583 40947 45714 53372';
        expect(fp.display, serverDisplay);
        expect(fp.canonical, serverDisplay.replaceAll(' ', ''));
      },
    );

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
