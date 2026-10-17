import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sodium_libs/sodium_libs.dart';

import 'package:nduzem/crypto/envelope.dart';
import 'package:nduzem/crypto/file_crypto.dart';
import 'package:nduzem/crypto/keys.dart';
import 'package:nduzem/crypto/sealed_box.dart';
import 'package:nduzem/features/transfers/envelope_peek.dart';
import 'package:nduzem/storage/secure_storage.dart';

import '../../crypto/sodium_test_support.dart';

/// In-memory stand-in: SecureStore talks to the platform keystore, which
/// does not exist under `flutter test`.
class _MemoryStore implements SecureStore {
  final Map<String, String> _m = {};
  @override
  Future<String?> read(String key) async => _m[key];
  @override
  Future<void> write(String key, String value) async => _m[key] = value;
  @override
  Future<void> delete(String key) async => _m.remove(key);
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() async {
  TestWidgetsFlutterBinding.ensureInitialized();

  final maybeSodium = await tryInitSodium();
  final skipReason = sodiumSkipReason(maybeSodium);

  late final Sodium sodium;
  late final Envelope envelope;
  late final FileCrypto fc;
  late final KeypairGenerator keys;
  if (maybeSodium != null) {
    sodium = maybeSodium;
    envelope = Envelope(sodium);
    fc = FileCrypto(sodium);
    keys = KeypairGenerator(sodium);
  }

  group(
    'EnvelopePeek',
    () {
      const userId = 'u-1';

      /// Build a real envelope for [owner], exactly as a sender would.
      ({String wrapped, String header}) seal(
        IdentityKeypair owner, {
        required String filename,
      }) {
        final fileKey = fc.generateFileKey();
        final wrapped = SealedBox(sodium).seal(
          message: fileKey,
          recipientIdentityPublic: owner.identityPublic,
        );
        final header = envelope.buildEncHeader(
          filename: filename,
          mime: 'application/pdf',
          plaintextLength: 4096,
          blobSha256Hex: 'ab' * 32,
          fileKey: fileKey,
        );
        return (
          wrapped: base64Encode(wrapped),
          header: base64Encode(header),
        );
      }

      Future<EnvelopePeek> peeker(IdentityKeypair? owner) async {
        final store = _MemoryStore();
        if (owner != null) {
          await store.write(
            SecureStore.identityPublicKeyFor(userId),
            base64Encode(owner.identityPublic),
          );
          await store.write(
            SecureStore.identityPrivateKeyFor(userId),
            base64Encode(owner.identityPrivate),
          );
        }
        return EnvelopePeek(
          sodium: sodium,
          sealedBox: SealedBox(sodium),
          envelope: envelope,
          storage: store,
        );
      }

      test('recovers the real filename on the owner device', () async {
        final owner = keys.generate();
        final e = seal(owner, filename: 'Passport scan.pdf');
        final header = await (await peeker(owner)).peek(
          userId: userId,
          wrappedKeyB64: e.wrapped,
          encHeaderB64: e.header,
          cryptoSuite: 1,
        );
        expect(header, isNotNull);
        expect(header!.filename, 'Passport scan.pdf');
        expect(header.mime, 'application/pdf');
        expect(header.plaintextLength, 4096);
      });

      test('another account cannot read it', () async {
        // The property the whole design rests on: the envelope opens on
        // the recipient's device and nowhere else.
        final owner = keys.generate();
        final stranger = keys.generate();
        final e = seal(owner, filename: 'secret.pdf');
        expect(
          await (await peeker(stranger)).peek(
            userId: userId,
            wrappedKeyB64: e.wrapped,
            encHeaderB64: e.header,
            cryptoSuite: 1,
          ),
          isNull,
        );
      });

      test('a device with no keys returns null, not an error', () async {
        // Restored from a backup, or a second account registered over
        // the top. A real case, and the right outcome is a row showing
        // its size rather than a screen showing a crash.
        final owner = keys.generate();
        final e = seal(owner, filename: 'x.pdf');
        expect(
          await (await peeker(null)).peek(
            userId: userId,
            wrappedKeyB64: e.wrapped,
            encHeaderB64: e.header,
            cryptoSuite: 1,
          ),
          isNull,
        );
      });

      test('link mode has no wrapped key and is not an error', () async {
        final owner = keys.generate();
        for (final absent in <String?>[null, '']) {
          expect(
            await (await peeker(owner)).peek(
              userId: userId,
              wrappedKeyB64: absent,
              encHeaderB64: 'aGVsbG8=',
              cryptoSuite: 1,
            ),
            isNull,
          );
        }
      });

      test('garbage does not escape as an exception', () async {
        final owner = keys.generate();
        expect(
          await (await peeker(owner)).peek(
            userId: userId,
            wrappedKeyB64: 'not base64 at all!!',
            encHeaderB64: 'nor is this',
            cryptoSuite: 1,
          ),
          isNull,
        );
      });
    },
    skip: skipReason,
  );
}
