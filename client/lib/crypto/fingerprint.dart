import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Safety number / fingerprint from `(identity_pub || signing_pub)`
/// (spec §6, matches server-side `key_fingerprint` in `app/core/security.py`).
///
/// **Algorithm** (Signal-style):
///   1. digest = SHA-256(identity_pub || signing_pub)
///   2. take the first 16 bytes, reduce modulo 10^25
///   3. render as five 5-digit base-10 groups, space-separated
///
/// e.g. `12345 67890 12345 67890 12345` — 25 digits + 4 spaces = 29 chars.
///
/// Five groups address exactly 10^25 (~2^83), so reducing modulo that
/// uses the whole display. An earlier version masked to 60 bits instead;
/// because 2^60 < 100000^4 the leading group was **always** `00000` and
/// the second never exceeded `01152`, so roughly 8 of the 25 digits
/// carried no information while costing the same to read aloud. Real
/// strength was 60 bits — grinding a colliding fingerprint cost ~2^60
/// keypair generations, which is no longer a comfortable margin. This is
/// ~2^23 times harder at identical length.
///
/// **Must stay byte-for-byte identical to `key_fingerprint` in the
/// server's `app/core/security.py`.** The client recomputes this from
/// the public keys the server returns and refuses to send when the two
/// disagree — that check is the defence against a substituted key, so a
/// divergence does not degrade gracefully, it blocks sending outright.
/// Shared golden vectors on both sides guard the invariant.
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

/// 10^25 — the exact number of values five 5-digit groups can express.
final BigInt _fingerprintModulus = BigInt.parse('10000000000000000000000000');

/// Which derivation produced a given fingerprint string.
///
/// Bumped when [fingerprintOf] changes, so anything that PERSISTED a
/// fingerprint can tell "computed differently" from "the key changed".
/// Those must never be conflated: the second raises a key-substitution
/// alarm, and raising it for every stored contact after an upgrade
/// teaches users the alarm means "the app updated".
///
///   1 — SHA-256 masked to 60 bits (leading group always `00000`)
///   2 — SHA-256[:16] mod 10^25, using the full 25-digit space
const int fingerprintSchemeVersion = 2;

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

  // First 16 bytes → reduce mod 10^25. Matches the server's
  // `int.from_bytes(digest[:16], "big") % 10**25`. Sixteen bytes
  // (2^128) into a 10^25 modulus leaves a bias below 2^-100.
  var n = BigInt.zero;
  for (var i = 0; i < 16; i++) {
    n = (n << 8) | BigInt.from(digest[i]);
  }
  n = n % _fingerprintModulus;

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
