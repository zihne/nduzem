import 'dart:convert';
import 'dart:typed_data';

import 'package:sodium_libs/sodium_libs.dart';

import 'keys.dart';

/// Encrypted backup of the identity keypair, unlocked by a recovery key
/// the user holds and the server never sees (ADR-0017).
///
/// **Why this exists.** The identity private key had exactly one copy,
/// in device storage. On web that storage is evictable — WebKit deletes
/// all script-writable storage after seven days of Safari use without
/// interaction — so a user could lose the ability to decrypt anything
/// ever sent to them without doing anything wrong, and with no way back.
/// Key rotation un-bricks the account but recovers nothing. This is the
/// piece that actually recovers.
///
/// **Why a generated key and not the password.** Password-wrapped escrow
/// would solve the same problem and is what most products do. It also
/// moves the password from being the root of AUTHENTICATION to the root
/// of the CRYPTOSYSTEM: the server already stores an argon2id hash, so
/// an attacker with the database can already grind it — what changes is
/// the payoff. Today cracking it yields account access and ciphertext;
/// with password escrow it yields the identity key and every transfer
/// ever sealed to it. At our KDF parameters a typical human-chosen
/// password falls in roughly an hour on rented hardware, which would
/// make whitepaper §2.2 false for most users.
///
/// 128 bits of CSPRNG output does not have that problem. The cost moves
/// from cryptography to UX — the user must actually keep the key — and
/// that is a cost we can be honest about rather than one we hide.
class RecoveryKey {
  const RecoveryKey._(this.bytes);

  /// Raw key material. 16 bytes = 128 bits: far beyond brute force, and
  /// short enough to print on one line, which matters for something a
  /// person is expected to write down.
  final Uint8List bytes;

  static const int lengthBytes = 16;

  /// Domain separator mixed into the wrapping-key derivation. Not a
  /// secret — it exists so this key cannot be confused with one derived
  /// from the same material for another purpose later.
  static const String _kdfContext = 'opaqueshare/recovery-key/v1';

  /// Crockford base32: no I, L, O or U. Those are the characters people
  /// mis-transcribe as 1, 1, 0 and V when copying by hand, and this
  /// string exists specifically to be copied by hand.
  static const String _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

  static RecoveryKey generate(Sodium sodium) =>
      RecoveryKey._(sodium.randombytes.buf(lengthBytes));

  /// Parse from anything a user might paste or type: with or without
  /// separators, any case, and with the digits people substitute for the
  /// excluded letters mapped back. Returns null if it is not a
  /// well-formed key.
  static RecoveryKey? tryParse(String input) {
    final cleaned = input
        .toUpperCase()
        .replaceAll(RegExp(r'[\s\-]'), '')
        // Forgive the classic confusions in the direction a human makes
        // them. Crockford specifies exactly this mapping.
        .replaceAll('O', '0')
        .replaceAll('I', '1')
        .replaceAll('L', '1');
    if (cleaned.length != _encodedLength) return null;

    var acc = 0;
    var bits = 0;
    final out = <int>[];
    for (final ch in cleaned.split('')) {
      final v = _alphabet.indexOf(ch);
      if (v < 0) return null;
      acc = (acc << 5) | v;
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        out.add((acc >> bits) & 0xff);
      }
    }
    if (out.length != lengthBytes) return null;
    return RecoveryKey._(Uint8List.fromList(out));
  }

  // 128 bits / 5 bits per character, rounded up.
  static const int _encodedLength = 26;

  /// The form shown to the user: uppercase base32 in groups of five.
  /// Grouping is not decoration — it is what makes a 26-character string
  /// checkable by eye when someone reads it back.
  String get display {
    final buf = StringBuffer();
    var acc = 0;
    var bits = 0;
    var written = 0;
    for (final b in bytes) {
      acc = (acc << 8) | b;
      bits += 8;
      while (bits >= 5) {
        bits -= 5;
        if (written > 0 && written % 5 == 0) buf.write('-');
        buf.write(_alphabet[(acc >> bits) & 0x1f]);
        written++;
      }
    }
    if (bits > 0) {
      if (written > 0 && written % 5 == 0) buf.write('-');
      buf.write(_alphabet[(acc << (5 - bits)) & 0x1f]);
    }
    return buf.toString();
  }

  /// Derive the 32-byte key that actually encrypts the backup.
  ///
  /// Keyed BLAKE2b rather than a password KDF: the input is already 128
  /// bits of uniform CSPRNG output, so there is nothing for argon2 to
  /// stretch. Running one anyway would cost seconds on a phone and buy
  /// nothing measurable.
  Uint8List _wrappingKey(Sodium sodium) {
    final key = SecureKey.fromList(sodium, bytes);
    try {
      return sodium.crypto.genericHash(
        message: Uint8List.fromList(utf8.encode(_kdfContext)),
        key: key,
        outLen: sodium.crypto.secretBox.keyBytes,
      );
    } finally {
      key.dispose();
    }
  }
}

/// Container magic. A wrong or corrupted blob then fails with something
/// that names the problem, rather than as an authentication failure that
/// looks identical to a mistyped recovery key.
final Uint8List _magic = Uint8List.fromList(utf8.encode('OSRK'));
const int _formatVersion = 1;

/// Wrap [pair] under [recovery]. The result is what the server stores:
/// opaque bytes it has no key for, exactly like `wrapped_key` and the
/// link-mode fragment.
///
/// Layout: `"OSRK" | version(1) | nonce(24) | secretbox(payload)`
Uint8List wrapKeypairForBackup({
  required Sodium sodium,
  required RecoveryKey recovery,
  required IdentityKeypair pair,
  required String fingerprint,
}) {
  final payload = utf8.encode(
    jsonEncode(<String, dynamic>{
      'v': _formatVersion,
      'identity_private': base64Encode(pair.identityPrivate),
      'identity_public': base64Encode(pair.identityPublic),
      'signing_private': base64Encode(pair.signingPrivate),
      'signing_public': base64Encode(pair.signingPublic),
      // Carried so a restore can tell "this backup is for a key you have
      // since replaced" apart from "you typed the recovery key wrong".
      // Both otherwise present as a working unwrap that does not decrypt
      // anything, which is a miserable thing to debug from a support
      // email.
      'fingerprint': fingerprint,
    }),
  );

  final wrapping = recovery._wrappingKey(sodium);
  final key = SecureKey.fromList(sodium, wrapping);
  try {
    final nonce = sodium.randombytes.buf(sodium.crypto.secretBox.nonceBytes);
    final ct = sodium.crypto.secretBox.easy(
      message: Uint8List.fromList(payload),
      nonce: nonce,
      key: key,
    );
    return (BytesBuilder(copy: false)
          ..add(_magic)
          ..addByte(_formatVersion)
          ..add(nonce)
          ..add(ct))
        .toBytes();
  } finally {
    key.dispose();
  }
}

/// Recovered keypair plus the fingerprint the backup was taken at.
class RestoredKeypair {
  const RestoredKeypair({required this.pair, required this.fingerprint});
  final IdentityKeypair pair;
  final String fingerprint;
}

/// Unwrap a backup. Throws [FormatException] when the blob is not a
/// backup at all, and [RecoveryKeyMismatch] when it is one but this key
/// does not open it — a distinction the user needs, because only the
/// second means "check what you typed".
RestoredKeypair unwrapKeypairFromBackup({
  required Sodium sodium,
  required RecoveryKey recovery,
  required Uint8List blob,
}) {
  final headerLen = _magic.length + 1;
  final nonceLen = sodium.crypto.secretBox.nonceBytes;
  if (blob.length <= headerLen + nonceLen) {
    throw const FormatException('Backup is too short to be valid.');
  }
  for (var i = 0; i < _magic.length; i++) {
    if (blob[i] != _magic[i]) {
      throw const FormatException(
        'This does not look like an OpaqueShare key backup.',
      );
    }
  }
  final version = blob[_magic.length];
  if (version != _formatVersion) {
    throw FormatException(
      'This backup was written in format v$version, which this app does '
      'not understand. Update the app and try again.',
    );
  }

  final nonce = blob.sublist(headerLen, headerLen + nonceLen);
  final ct = blob.sublist(headerLen + nonceLen);
  final wrapping = recovery._wrappingKey(sodium);
  final key = SecureKey.fromList(sodium, wrapping);
  late final Uint8List plain;
  try {
    plain = sodium.crypto.secretBox.openEasy(
      cipherText: ct,
      nonce: nonce,
      key: key,
    );
  } on Object {
    // secretbox is authenticated, so this is the only signal that the
    // key is wrong — and it is a reliable one.
    throw const RecoveryKeyMismatch();
  } finally {
    key.dispose();
  }

  final map = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
  Uint8List field(String name) =>
      Uint8List.fromList(base64Decode(map[name] as String));

  return RestoredKeypair(
    pair: IdentityKeypair(
      identityPublic: field('identity_public'),
      identityPrivate: field('identity_private'),
      signingPublic: field('signing_public'),
      signingPrivate: field('signing_private'),
    ),
    fingerprint: map['fingerprint'] as String? ?? '',
  );
}

/// The blob is a real backup, but this recovery key does not open it.
class RecoveryKeyMismatch implements Exception {
  const RecoveryKeyMismatch();

  @override
  String toString() =>
      'That recovery key does not unlock this backup. Check for '
      'mistyped characters, or make sure it is the key for this account.';
}


/// The backup opened correctly, but holds a keypair the account no
/// longer advertises.
///
/// Reachable whenever a key rotation happened after the backup was
/// taken: the ciphertext still decrypts perfectly and yields a key the
/// account no longer publishes, so nobody will seal to it. Every
/// visible step succeeds and then nothing decrypts, which is why this
/// is a distinct failure rather than a generic one — the user needs to
/// be told the backup is old, not that they typed something wrong.
class StaleKeyBackup implements Exception {
  const StaleKeyBackup({
    required this.backupFingerprint,
    required this.currentFingerprint,
  });

  final String backupFingerprint;
  final String currentFingerprint;

  @override
  String toString() =>
      'This backup holds an older key ($backupFingerprint). Your account '
      'now uses $currentFingerprint, so restoring would not let you open '
      'anything. It was most likely made before you replaced your key.';
}
