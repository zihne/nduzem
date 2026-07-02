import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Safety number / fingerprint from `(identity_pub || signing_pub)`
/// (spec §6, matches server-side `key_fingerprint` in `app/core/security.py`).
///
/// **Algorithm** (Signal-style):
///   1. digest = SHA-256(identity_pub || signing_pub)
///   2. take first 8 bytes of the digest, mask to 60 bits
///   3. render as five 5-digit base-10 groups, space-separated
///
/// e.g. `12345 67890 12345 67890 12345` — 25 digits + 4 spaces = 29 chars.
///
/// 60 bits ≈ 1e18 possible values. Grinding a colliding fingerprint against
/// a specific target key takes ~2^60 keypair operations — enough to make a
/// key-substitution attack observably expensive under this display, while
/// keeping the string short enough to read aloud in ~10 seconds.
///
/// Used for:
///   - Displaying the recipient's fingerprint at send time (TOFU).
///   - Raising a `key-changed` alert when a counterparty's fingerprint
///     moves between sessions.
///   - Out-of-band verification via voice, video, QR, or copy-paste.
class Fingerprint {
  const Fingerprint(this.canonical);

  /// Canonical form: 25 decimal digits, no spaces. Used for storage,
  /// comparison, and QR embedding. Two fingerprints are equal iff their
  /// canonical strings match.
  final String canonical;

  /// Display form: five groups of five digits, space-separated. Used on
  /// screen and when reading aloud.
  String get display {
    final buf = StringBuffer();
    for (var i = 0; i < canonical.length; i += 5) {
      if (i > 0) buf.write(' ');
      buf.write(canonical.substring(i, i + 5));
    }
    return buf.toString();
  }

  /// Constant-time equality against another canonical (or display-form)
  /// string. Whitespace is stripped so users pasting from a "read-aloud"
  /// context don't hit false mismatches.
  bool matches(String other) {
    final normalised = other.replaceAll(RegExp(r'\s+'), '');
    if (normalised.length != canonical.length) return false;
    var diff = 0;
    for (var i = 0; i < canonical.length; i++) {
      diff |= canonical.codeUnitAt(i) ^ normalised.codeUnitAt(i);
    }
    return diff == 0;
  }

  @override
  bool operator ==(Object other) =>
      other is Fingerprint && other.canonical == canonical;

  @override
  int get hashCode => canonical.hashCode;

  @override
  String toString() => display;
}

/// Derive the fingerprint. Inputs are the raw public-key bytes exactly as
/// they were generated / uploaded — NOT the base64 encoding.
Fingerprint fingerprintOf({
  required Uint8List identityPublic,
  required Uint8List signingPublic,
}) {
  final concat = BytesBuilder(copy: false)
    ..add(identityPublic)
    ..add(signingPublic);
  final digest = sha256.convert(concat.toBytes()).bytes;

  // First 8 bytes → uint64 → mask to 60 bits. Matches the server's
  // `int.from_bytes(digest[:8], "big") & ((1 << 60) - 1)`.
  var n = BigInt.zero;
  for (var i = 0; i < 8; i++) {
    n = (n << 8) | BigInt.from(digest[i]);
  }
  n = n & ((BigInt.one << 60) - BigInt.one);

  // Extract 5 base-100000 digits, most-significant first.
  final groups = <String>[];
  final base = BigInt.from(100000);
  for (var i = 0; i < 5; i++) {
    groups.add((n % base).toInt().toString().padLeft(5, '0'));
    n = n ~/ base;
  }
  final canonical = groups.reversed.join();
  return Fingerprint(canonical);
}

/// Parse a fingerprint from any human-typed / clipboard form. Accepts the
/// canonical `1234567890...` and any space-grouped variant. Returns null
/// if the input isn't 25 decimal digits after whitespace stripping.
Fingerprint? tryParseFingerprint(String input) {
  final normalised = input.replaceAll(RegExp(r'\s+'), '');
  if (normalised.length != 25) return null;
  if (!RegExp(r'^\d{25}$').hasMatch(normalised)) return null;
  return Fingerprint(normalised);
}
