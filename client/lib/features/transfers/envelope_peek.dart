import 'dart:convert';
import 'dart:typed_data';

import 'package:sodium_libs/sodium_libs.dart';

import '../../crypto/envelope.dart';
import '../../crypto/sealed_box.dart';
import '../../crypto/suite.dart';
import '../../crypto/suite_keys.dart';
import '../../storage/secure_storage.dart';

/// Read a transfer's metadata — filename, type, size — without
/// downloading it.
///
/// Everything here happens on this device with this account's own keys.
/// `wrapped_key` is sealed to the owner's X25519 public key, so the
/// server stores it and cannot open it; opening it locally is not a
/// concession to the zero-knowledge model, it *is* the model, and it is
/// what the receive screen already does for every transfer.
///
/// WHY THIS IS SEPARATE FROM THE RECEIVE PATH. `/download` is the only
/// endpoint that used to hand over `wrapped_key`, and it increments the
/// download counter. Drop uploads allow exactly one download, so
/// fetching filenames that way would have spent it — a list of five
/// arrivals would leave the owner unable to open any of them. The list
/// endpoints now return `wrapped_key` directly and touch no counter;
/// this class is the client half of that.
///
/// It returns **null** rather than throwing on any failure. A list view
/// must not break because one row cannot be opened — a transfer sealed
/// to a key this device no longer holds (restored from a backup, or a
/// second account registered over the top) is a real case, and the right
/// outcome is a row that shows its size and not a screen that shows an
/// error.
class EnvelopePeek {
  const EnvelopePeek({
    required Sodium sodium,
    required SealedBox sealedBox,
    required Envelope envelope,
    required SecureStore storage,
  })  : _sodium = sodium,
        _sealedBox = sealedBox,
        _envelope = envelope,
        _storage = storage;

  final Sodium _sodium;
  final SealedBox _sealedBox;
  final Envelope _envelope;
  final SecureStore _storage;

  Future<DecryptedHeader?> peek({
    required String userId,
    required String? wrappedKeyB64,
    required String encHeaderB64,
    required int cryptoSuite,
  }) async {
    // Link-mode transfers have no wrapped_key at all — K_file rides in
    // the URL fragment — so there is nothing to open here.
    if (wrappedKeyB64 == null || wrappedKeyB64.isEmpty) return null;
    try {
      final pub = await _storage.read(SecureStore.identityPublicKeyFor(userId));
      final priv =
          await _storage.read(SecureStore.identityPrivateKeyFor(userId));
      if (pub == null || priv == null) return null;

      final fileKey = _sealedBox.sealOpen(
        ciphertext: base64Decode(wrappedKeyB64),
        recipientIdentityPublic: Uint8List.fromList(base64Decode(pub)),
        recipientIdentityPrivate: Uint8List.fromList(base64Decode(priv)),
      );
      // The envelope's OWN suite, not whatever this build sends with: a
      // transfer created under an earlier suite must still open.
      final suiteKeys = SuiteKeys.derive(
        _sodium,
        fileKey,
        CryptoSuite.fromWire(cryptoSuite),
      );
      return _envelope.openEncHeader(
        encHeader: Uint8List.fromList(base64Decode(encHeaderB64)),
        fileKey: suiteKeys.headerKey,
      );
    } on Object {
      // Deliberately broad. Wrong device, rotated key, malformed base64,
      // a suite this build does not know: every one of them means "we
      // cannot show a name", and none of them should take the list with
      // it.
      return null;
    }
  }
}
