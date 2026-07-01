import 'package:flutter_test/flutter_test.dart';
import 'package:opaqueshare/crypto/suite.dart';

void main() {
  test('fromWire(1) returns classical', () {
    expect(CryptoSuite.fromWire(1), CryptoSuite.classical);
  });

  test('unknown suite throws — spec §2.6 fail-closed rule', () {
    expect(() => CryptoSuite.fromWire(99), throwsA(isA<UnsupportedError>()));
  });
}
