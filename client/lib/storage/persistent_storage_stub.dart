/// Non-web stub. Native platforms store the identity keypair in the
/// Keychain / EncryptedSharedPreferences, which the OS does not evict on
/// an inactivity timer, so there is nothing to request.
Future<bool> requestPersistentStorage() async => false;
