/// Crypto-suite versioning (spec §2.6).
///
/// Every envelope carries a `crypto_suite` identifier so a future
/// suite (e.g. hybrid X25519 + ML-KEM PQC) can coexist with existing
/// ciphertext. The v1 client only knows suite 1; any envelope carrying
/// an unknown suite MUST fail closed rather than silently mis-decrypt.
enum CryptoSuite {
  /// suite=1: classical — X25519 (identity) + Ed25519 (signing) +
  /// XChaCha20-Poly1305 (secretstream). Ships in v1.
  classical(1);

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
