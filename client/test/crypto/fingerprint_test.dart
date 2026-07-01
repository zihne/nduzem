import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:opaqueshare/crypto/fingerprint.dart';

void main() {
  group('fingerprintOf', () {
    test('produces a 64-char raw hex and a 60-char display string', () {
      final id = Uint8List.fromList(List.filled(32, 1));
      final sig = Uint8List.fromList(List.filled(32, 2));
      final fp = fingerprintOf(identityPublic: id, signingPublic: sig);
      expect(fp.rawHex.length, 64);
      // 12 groups of 5 hex chars, 11 separators = 60 + 11 = 71 characters.
      expect(fp.formatted.length, 71);
      expect(fp.formatted.split(' '), hasLength(12));
    });

    test('is deterministic for the same inputs', () {
      final id = Uint8List.fromList(List.filled(32, 42));
      final sig = Uint8List.fromList(List.filled(32, 84));
      final a = fingerprintOf(identityPublic: id, signingPublic: sig);
      final b = fingerprintOf(identityPublic: id, signingPublic: sig);
      expect(a, equals(b));
      expect(fingerprintsMatch(a, b), isTrue);
    });

    test('changes if either key changes', () {
      final id = Uint8List.fromList(List.filled(32, 1));
      final sig = Uint8List.fromList(List.filled(32, 2));
      final base = fingerprintOf(identityPublic: id, signingPublic: sig);

      final idPrime = Uint8List.fromList(List.filled(32, 1))..[0] = 99;
      final flipId =
          fingerprintOf(identityPublic: idPrime, signingPublic: sig);
      expect(fingerprintsMatch(base, flipId), isFalse);

      final sigPrime = Uint8List.fromList(List.filled(32, 2))..[0] = 99;
      final flipSig =
          fingerprintOf(identityPublic: id, signingPublic: sigPrime);
      expect(fingerprintsMatch(base, flipSig), isFalse);
    });

    test('constant-time compare distinguishes different lengths', () {
      final a = Fingerprint('short', 'abc');
      final b = Fingerprint(
        'ab cde fg h ijk lmn op qr st uvwxy z 12 34 5678 9',
        'a' * 64,
      );
      expect(fingerprintsMatch(a, b), isFalse);
    });
  });
}
