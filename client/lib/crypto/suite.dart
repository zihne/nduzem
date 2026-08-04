/// Crypto-suite versioning (spec §2.6).
///
/// Every envelope carries a `crypto_suite` identifier so a future
/// suite (e.g. hybrid X25519 + ML-KEM PQC) can coexist with existing
/// ciphertext. The v1 client only knows suite 1; any envelope carrying
/// an unknown suite MUST fail closed rather than silently mis-decrypt.
enum CryptoSuite {
  /// suite=1: classical — X25519 (identity) + Ed25519 (signing) +
  /// XChaCha20-Poly1305 (secretstream). Ships in v1.
  ///
  /// K_file is used **directly** with two different primitives: the
  /// secretstream for the body and the secretbox for `enc_header`.
  /// Still readable so transfers created before suite 2 — and any in
  /// flight across a deploy — continue to open.
  classical(1),

  /// suite=2: as suite 1, but the body and header keys are separate
  /// subkeys derived from K_file with `crypto_kdf_derive_from_key`
  /// rather than K_file being handed to both primitives.
  ///
  /// Suite 1 is not known to be breakable — secretstream derives its
  /// own subkey via HChaCha20 from a random 24-byte header, and
  /// XSalsa20 derives one via HSalsa20 from a random 24-byte nonce, so
  /// the two never see the same input to the same function. But "one
  /// key, two constructions" is a property you have to argue your way
  /// out of, and the argument depends on internals of both primitives.
  /// Domain-separated subkeys make it a non-question.
  classicalSplitKeys(2);

  const CryptoSuite(this.wireValue);

  /// The integer that travels on the wire. Matches the backend enum.
  final int wireValue;

  /// Parse from the wire. Unknown values throw — see the file docstring
  /// on the "fail closed" rule.
  static CryptoSuite fromWire(int value) {
    for (final s in CryptoSuite.values) {
      if (s.wireValue == value) return s;
    }
    throw UnsupportedError(
      'Unknown crypto_suite=$value; client only knows '
      '${CryptoSuite.values.map((s) => s.wireValue).join(",")}.',
    );
  }
}
