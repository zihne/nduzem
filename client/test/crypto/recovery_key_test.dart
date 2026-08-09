// Encrypted key backup, unlocked by a user-held recovery key (ADR-0017).
//
// The identity private key had one copy, in device storage. On web that
// storage is evictable — WebKit clears all script-writable storage after
// seven days of Safari use without interaction — so a user could lose
// the ability to decrypt everything ever sent to them without doing
// anything wrong. Rotation un-bricks the account; this is the piece that
// actually recovers.
//
// The property under test throughout: the server holds bytes it cannot
// open, and only the 128-bit key the user holds opens them.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:opaqueshare/crypto/keys.dart';
import 'package:opaqueshare/crypto/recovery_key.dart';
import 'package:sodium_libs/sodium_libs.dart';

import 'sodium_test_support.dart';

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();

  final maybeSodium = await tryInitSodium();
  final skipReason = sodiumSkipReason(maybeSodium);
  late final Sodium sodium;
  late final KeypairGenerator keys;
  if (maybeSodium != null) {
    sodium = maybeSodium;
    keys = KeypairGenerator(maybeSodium);
  }

  const fingerprint = '1234567890123456789012345';

  group(
    'recovery key',
    () {
      test('is 128 bits of entropy, and different every time', () {
        final a = RecoveryKey.generate(sodium);
        final b = RecoveryKey.generate(sodium);
        expect(a.bytes.length, RecoveryKey.lengthBytes);
        expect(a.bytes.length * 8, 128);
        expect(a.bytes, isNot(b.bytes));
      });

      test('round-trips through its displayed form', () {
        // The display form is the whole product here: it is what the
        // user writes down and types back. If it does not round-trip,
        // the backup is unrecoverable in exactly the situation it exists
        // for.
        for (var i = 0; i < 200; i++) {
          final key = RecoveryKey.generate(sodium);
          final parsed = RecoveryKey.tryParse(key.display);
          expect(parsed, isNotNull, reason: 'failed to parse ${key.display}');
          expect(parsed!.bytes, key.bytes, reason: key.display);
        }
      });

      test('uses no character a person confuses when copying', () {
        // Crockford base32 omits I, L, O and U. Someone reading a key
        // aloud from a printout is the expected case, so an alphabet
        // containing both O and 0 would manufacture support tickets.
        for (var i = 0; i < 100; i++) {
          final shown = RecoveryKey.generate(sodium).display;
          expect(shown, isNot(matches(RegExp('[ILOU]'))));
        }
      });

      test('forgives the substitutions people actually make', () {
        final key = RecoveryKey.generate(sodium);
        final mangled = key.display
            .replaceAll('0', 'O')
            .replaceAll('1', 'l')
            .toLowerCase()
            .replaceAll('-', ' ');
        expect(RecoveryKey.tryParse(mangled)?.bytes, key.bytes);
      });

      test('rejects input that is not a key', () {
        expect(RecoveryKey.tryParse(''), isNull);
        expect(RecoveryKey.tryParse('too-short'), isNull);
        // Right length, but U is not in the alphabet.
        expect(RecoveryKey.tryParse('U' * 26), isNull);
      });

      // --- the backup itself ---------------------------------------

      test('wraps and unwraps a keypair', () {
        final pair = keys.generate();
        final recovery = RecoveryKey.generate(sodium);
        final blob = wrapKeypairForBackup(
          sodium: sodium,
          recovery: recovery,
          pair: pair,
          fingerprint: fingerprint,
        );

        final restored = unwrapKeypairFromBackup(
          sodium: sodium,
          recovery: recovery,
          blob: blob,
        );
        expect(restored.pair.identityPrivate, pair.identityPrivate);
        expect(restored.pair.identityPublic, pair.identityPublic);
        expect(restored.pair.signingPrivate, pair.signingPrivate);
        expect(restored.pair.signingPublic, pair.signingPublic);
        expect(restored.fingerprint, fingerprint);
      });

      test('the blob leaks no key material to whoever stores it', () {
        // The server holds this. If any private key were recoverable
        // from it without the recovery key, the whole design is void.
        final pair = keys.generate();
        final blob = wrapKeypairForBackup(
          sodium: sodium,
          recovery: RecoveryKey.generate(sodium),
          pair: pair,
          fingerprint: fingerprint,
        );
        expect(_contains(blob, pair.identityPrivate), isFalse);
        expect(_contains(blob, pair.signingPrivate), isFalse);
        // Nor the public halves or fingerprint — not secret, but their
        // presence would mean the payload was not encrypted at all.
        expect(_contains(blob, pair.identityPublic), isFalse);
        expect(
          _contains(blob, Uint8List.fromList(utf8.encode(fingerprint))),
          isFalse,
        );
      });

      test('a different recovery key does not open it', () {
        final blob = wrapKeypairForBackup(
          sodium: sodium,
          recovery: RecoveryKey.generate(sodium),
          pair: keys.generate(),
          fingerprint: fingerprint,
        );
        expect(
          () => unwrapKeypairFromBackup(
            sodium: sodium,
            recovery: RecoveryKey.generate(sodium),
            blob: blob,
          ),
          throwsA(isA<RecoveryKeyMismatch>()),
        );
      });

      test('a tampered blob is refused, not silently accepted', () {
        // secretbox is authenticated; this asserts we actually rely on
        // that rather than decrypting whatever we are handed.
        final recovery = RecoveryKey.generate(sodium);
        final blob = wrapKeypairForBackup(
          sodium: sodium,
          recovery: recovery,
          pair: keys.generate(),
          fingerprint: fingerprint,
        );
        for (final i in [blob.length - 1, blob.length ~/ 2]) {
          final tampered = Uint8List.fromList(blob);
          tampered[i] ^= 0x01;
          expect(
            () => unwrapKeypairFromBackup(
              sodium: sodium,
              recovery: recovery,
              blob: tampered,
            ),
            throwsA(isA<RecoveryKeyMismatch>()),
            reason: 'byte $i',
          );
        }
      });

      test('a wrong key and a non-backup are distinguishable', () {
        // The user needs these to read differently: one means "check
        // what you typed", the other means "that is the wrong file".
        // Reporting both as an authentication failure sends people
        // hunting for a typo that is not there.
        final recovery = RecoveryKey.generate(sodium);
        expect(
          () => unwrapKeypairFromBackup(
            sodium: sodium,
            recovery: recovery,
            blob: Uint8List.fromList(List.filled(200, 7)),
          ),
          throwsA(isA<FormatException>()),
        );
      });

      test('the fingerprint rides along so a stale backup is detectable',
          () {
        // After a key rotation an old backup still unwraps perfectly —
        // it just contains a key nobody can send to any more. Without
        // this field that is indistinguishable from success right up
        // until nothing decrypts.
        final recovery = RecoveryKey.generate(sodium);
        final blob = wrapKeypairForBackup(
          sodium: sodium,
          recovery: recovery,
          pair: keys.generate(),
          fingerprint: 'OLDFINGERPRINT0000000000',
        );
        final restored = unwrapKeypairFromBackup(
          sodium: sodium,
          recovery: recovery,
          blob: blob,
        );
        expect(restored.fingerprint, 'OLDFINGERPRINT0000000000');
      });
    },
    skip: skipReason,
  );
}

bool _contains(Uint8List haystack, Uint8List needle) {
  if (needle.isEmpty || needle.length > haystack.length) return false;
  for (var i = 0; i <= haystack.length - needle.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) return true;
  }
  return false;
}
