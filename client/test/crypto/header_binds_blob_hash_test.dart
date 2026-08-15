import 'package:flutter_test/flutter_test.dart';
import 'package:nduzem/crypto/envelope.dart';

/// `enc_header` carries its own `blob_sha256`, sealed under K_file —
/// the one hash in the envelope the server cannot forge. It was decoded
/// into `DecryptedHeader` and then never read: every check in the
/// receive path used the server-supplied value, so the field documented
/// as letting the recipient "re-verify locally without trusting the
/// download response" did nothing at all.
///
/// No sodium needed — this is string comparison, deliberately extracted
/// from `TransferService` so it is reachable from a test at all. It was
/// previously a private method on a class with no test coverage.
void main() {
  final good = 'a' * 64;

  test('agreeing hashes pass', () {
    assertHeaderBindsBlobHash(
      headerBlobSha256Hex: good,
      serverBlobSha256Hex: good,
    );
  });

  test('a server claiming a different ciphertext is refused', () {
    // The attack this closes: storage and database tampered with
    // independently. The blob and the reported hash agree with each
    // other, but neither matches what the sender actually sealed.
    expect(
      () => assertHeaderBindsBlobHash(
        headerBlobSha256Hex: good,
        serverBlobSha256Hex: 'b' * 64,
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('case differences are tolerated', () {
    // Both sides should emit lowercase; a case difference is a
    // formatting quirk, not a tampering signal. Failing on it would be
    // a self-inflicted outage, not a security win.
    assertHeaderBindsBlobHash(
      headerBlobSha256Hex: 'AB' * 32,
      serverBlobSha256Hex: 'ab' * 32,
    );
  });

  test('an empty header hash does not silently pass', () {
    // `openEncHeader` defaults a missing `blob_sha256` to '' rather
    // than throwing, so a header without the field must not be treated
    // as agreeing with whatever the server said.
    expect(
      () => assertHeaderBindsBlobHash(
        headerBlobSha256Hex: '',
        serverBlobSha256Hex: good,
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('the error names both values so a mismatch is diagnosable', () {
    try {
      assertHeaderBindsBlobHash(
        headerBlobSha256Hex: good,
        serverBlobSha256Hex: 'b' * 64,
      );
      fail('expected a StateError');
    } on StateError catch (e) {
      expect(e.message, contains(good));
      expect(e.message, contains('b' * 64));
    }
  });
}
