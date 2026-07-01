import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Safety number / fingerprint from `(identity_pub || signing_pub)`
/// (spec §6). Used for:
///
/// - Displaying the recipient's fingerprint at send time (TOFU).
/// - Raising a `key-changed` alert when a counterparty's fingerprint
///   moves between sessions.
///
/// The format is 60 characters of the SHA-256 hex digest, split into
/// 12 groups of 5 characters separated by spaces. That's ~240 bits of
/// entropy — well past collision resistance — while staying readable
/// aloud.
class Fingerprint {
  const Fingerprint(this.formatted, this.rawHex);

  /// Space-grouped for display: `"a1b2c 3d4e5 ... 90abc"`.
  final String formatted;

  /// Full 64-hex-character SHA-256 digest; useful when the client needs
  /// to compare against a value the backend echoes back (e.g. after a
  /// signup response).
  final String rawHex;

  @override
  bool operator ==(Object other) =>
      other is Fingerprint && other.rawHex == rawHex;

  @override
  int get hashCode => rawHex.hashCode;

  @override
  String toString() => formatted;
}

/// Derive the fingerprint. Inputs are the raw public-key bytes exactly
/// as they were generated / uploaded — NOT the base64 encoding.
Fingerprint fingerprintOf({
  required Uint8List identityPublic,
  required Uint8List signingPublic,
}) {
  final concat = BytesBuilder(copy: false)
    ..add(identityPublic)
    ..add(signingPublic);
  final digest = sha256.convert(concat.toBytes());
  final hex = _hex(digest.bytes);
  return Fingerprint(_groupForDisplay(hex.substring(0, 60)), hex);
}

/// Format a fingerprint for on-screen display or QR-encoded exchange.
String _groupForDisplay(String hex) {
  final buf = StringBuffer();
  for (var i = 0; i < hex.length; i += 5) {
    if (i > 0) buf.write(' ');
    buf.write(hex.substring(i, i + 5));
  }
  return buf.toString();
}

String _hex(List<int> bytes) {
  return bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
}

/// Compare two fingerprints in constant time relative to their length —
/// don't leak a mismatch position via early-exit timing.
bool fingerprintsMatch(Fingerprint a, Fingerprint b) {
  if (a.rawHex.length != b.rawHex.length) return false;
  var diff = 0;
  for (var i = 0; i < a.rawHex.length; i++) {
    diff |= a.rawHex.codeUnitAt(i) ^ b.rawHex.codeUnitAt(i);
  }
  return diff == 0;
}
