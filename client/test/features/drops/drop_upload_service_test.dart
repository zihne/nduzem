import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sodium_libs/sodium_libs.dart';

import 'package:nduzem/api/drop_uploads_api.dart';
import 'package:nduzem/crypto/envelope.dart';
import 'package:nduzem/crypto/file_crypto.dart';
import 'package:nduzem/crypto/keys.dart';
import 'package:nduzem/crypto/plaintext_source.dart';
import 'package:nduzem/crypto/sealed_box.dart';
import 'package:nduzem/features/drops/drop_upload_service.dart';

import '../../crypto/sodium_test_support.dart';

class _FakeApi extends Mock implements DropUploadsApi {}

/// Bytes in memory. `openRead()` must be re-callable per ADR-0013, and
/// a list-backed stream is.
class _MemorySource implements PlaintextSource {
  _MemorySource(this.bytes);
  final List<int> bytes;
  @override
  int get lengthBytes => bytes.length;
  @override
  String get filename => 'passport.pdf';
  @override
  String? get mimeType => 'application/pdf';
  @override
  Stream<List<int>> openRead() => Stream<List<int>>.value(bytes);
}

void main() async {
  TestWidgetsFlutterBinding.ensureInitialized();

  final maybeSodium = await tryInitSodium();
  final skipReason = sodiumSkipReason(maybeSodium);

  // Non-nullable + late: a stray run fails loudly rather than passing
  // without executing an assertion.
  late final Sodium sodium;
  late final FileCrypto fc;
  late final Envelope envelope;
  late final KeypairGenerator keys;
  late final IdentityKeypair owner;
  if (maybeSodium != null) {
    sodium = maybeSodium;
    fc = FileCrypto(sodium);
    envelope = Envelope(sodium);
    keys = KeypairGenerator(sodium);
    owner = keys.generate(); // stands in for the drop's owner
  }

  setUpAll(() => registerFallbackValue(<String, dynamic>{}));

  DropUploadService build(
    _FakeApi api, {
    http.Client? client,
    List<http.Request>? captured,
  }) =>
      DropUploadService(
        api: api,
        sodium: sodium,
        fileCrypto: fc,
        envelope: envelope,
        keys: keys,
        httpClient: client ??
            MockClient((req) async {
              captured?.add(req);
              return http.Response('', 200);
            }),
      );

  void stubOpen(_FakeApi api, {int maxBytes = 10 * 1024 * 1024}) {
    when(() => api.info(any())).thenAnswer(
      (_) async => DropUploadInfo(
        open: true,
        maxBytes: maxBytes,
        passwordRequired: true,
      ),
    );
    when(
      () => api.initiate(
        dropId: any(named: 'dropId'),
        password: any(named: 'password'),
        byteCount: any(named: 'byteCount'),
      ),
    ).thenAnswer(
      (_) async => const DropUploadTicket(
        transferId: 't-1',
        storageKey: 'blobs/x',
        uploadUrl: 'https://storage.example/put',
      ),
    );
  }

  group(
    'DropUploadService.upload',
    () {
      test('seals K_file to the OWNER key from the fragment', () async {
        // The property the whole feature rests on: only the owner's
        // private key can recover K_file. If this ever seals to
        // anything else — a server-supplied key, say — the upload stops
        // being zero-knowledge while still appearing to work.
        final api = _FakeApi();
        stubOpen(api);
        String? wrappedB64;
        String? headerB64;
        String? sigB64;
        String? ephSignPub;
        when(
          () => api.commit(
            dropId: any(named: 'dropId'),
            password: any(named: 'password'),
            transferId: any(named: 'transferId'),
            blobSha256Hex: any(named: 'blobSha256Hex'),
            encHeaderB64: any(named: 'encHeaderB64'),
            signatureB64: any(named: 'signatureB64'),
            wrappedKeyB64: any(named: 'wrappedKeyB64'),
            senderIdentityPubB64: any(named: 'senderIdentityPubB64'),
            senderSigningPubB64: any(named: 'senderSigningPubB64'),
            cryptoSuite: any(named: 'cryptoSuite'),
          ),
        ).thenAnswer((inv) async {
          wrappedB64 = inv.namedArguments[const Symbol('wrappedKeyB64')] as String;
          headerB64 = inv.namedArguments[const Symbol('encHeaderB64')] as String;
          sigB64 = inv.namedArguments[const Symbol('signatureB64')] as String;
          ephSignPub =
              inv.namedArguments[const Symbol('senderSigningPubB64')] as String;
          return 1234;
        });

        final out = await build(api).upload(
          dropId: 'd-1',
          password: 'K7M2-PQRX-39TB',
          source: _MemorySource(List<int>.filled(4096, 7)),
          ownerIdentityPub: owner.identityPublic,
        );
        expect(out.transferId, 't-1');
        expect(out.byteCount, 1234);

        // The owner — and only the owner — can unseal it.
        final fileKey = SealedBox(sodium).sealOpen(
          ciphertext: base64Decode(wrappedB64!),
          recipientIdentityPublic: owner.identityPublic,
          recipientIdentityPrivate: owner.identityPrivate,
        );
        expect(fileKey.length, greaterThan(0));

        // And that key opens the header, so the envelope is coherent
        // rather than merely well-formed.
        final meta = envelope.openEncHeader(
          encHeader: base64Decode(headerB64!),
          fileKey: fileKey,
        );
        expect(meta.filename, 'passport.pdf');

        expect(base64Decode(sigB64!).length, 64);
        expect(base64Decode(ephSignPub!).length, 32);
      });

      test('a different key cannot unseal it', () async {
        final api = _FakeApi();
        stubOpen(api);
        String? wrappedB64;
        when(
          () => api.commit(
            dropId: any(named: 'dropId'),
            password: any(named: 'password'),
            transferId: any(named: 'transferId'),
            blobSha256Hex: any(named: 'blobSha256Hex'),
            encHeaderB64: any(named: 'encHeaderB64'),
            signatureB64: any(named: 'signatureB64'),
            wrappedKeyB64: any(named: 'wrappedKeyB64'),
            senderIdentityPubB64: any(named: 'senderIdentityPubB64'),
            senderSigningPubB64: any(named: 'senderSigningPubB64'),
            cryptoSuite: any(named: 'cryptoSuite'),
          ),
        ).thenAnswer((inv) async {
          wrappedB64 = inv.namedArguments[const Symbol('wrappedKeyB64')] as String;
          return 1;
        });

        await build(api).upload(
          dropId: 'd-1',
          password: 'pw',
          source: _MemorySource(List<int>.filled(64, 1)),
          ownerIdentityPub: owner.identityPublic,
        );

        final stranger = keys.generate();
        expect(
          () => SealedBox(sodium).sealOpen(
            ciphertext: base64Decode(wrappedB64!),
            recipientIdentityPublic: stranger.identityPublic,
            recipientIdentityPrivate: stranger.identityPrivate,
          ),
          throwsA(isA<Object>()),
        );
      });

      test('generates a fresh sender keypair for every upload', () async {
        // Reuse would create a correlatable pseudonym across uploads,
        // which is the one thing an unattributable mode must not leak.
        final api = _FakeApi();
        stubOpen(api);
        final seen = <String>[];
        when(
          () => api.commit(
            dropId: any(named: 'dropId'),
            password: any(named: 'password'),
            transferId: any(named: 'transferId'),
            blobSha256Hex: any(named: 'blobSha256Hex'),
            encHeaderB64: any(named: 'encHeaderB64'),
            signatureB64: any(named: 'signatureB64'),
            wrappedKeyB64: any(named: 'wrappedKeyB64'),
            senderIdentityPubB64: any(named: 'senderIdentityPubB64'),
            senderSigningPubB64: any(named: 'senderSigningPubB64'),
            cryptoSuite: any(named: 'cryptoSuite'),
          ),
        ).thenAnswer((inv) async {
          seen.add(
            inv.namedArguments[const Symbol('senderSigningPubB64')] as String,
          );
          return 1;
        });

        final svc = build(api);
        for (var i = 0; i < 3; i++) {
          await svc.upload(
            dropId: 'd-1',
            password: 'pw',
            source: _MemorySource(List<int>.filled(32, i)),
            ownerIdentityPub: owner.identityPublic,
          );
        }
        expect(seen.toSet().length, 3, reason: 'keys were reused');
      });

      test('PUTs the ciphertext, not the plaintext', () async {
        final api = _FakeApi();
        stubOpen(api);
        when(
          () => api.commit(
            dropId: any(named: 'dropId'),
            password: any(named: 'password'),
            transferId: any(named: 'transferId'),
            blobSha256Hex: any(named: 'blobSha256Hex'),
            encHeaderB64: any(named: 'encHeaderB64'),
            signatureB64: any(named: 'signatureB64'),
            wrappedKeyB64: any(named: 'wrappedKeyB64'),
            senderIdentityPubB64: any(named: 'senderIdentityPubB64'),
            senderSigningPubB64: any(named: 'senderSigningPubB64'),
            cryptoSuite: any(named: 'cryptoSuite'),
          ),
        ).thenAnswer((_) async => 1);

        final captured = <http.Request>[];
        final plaintext = Uint8List.fromList(
          utf8.encode('PASSPORT NUMBER 123456789' * 40),
        );
        await build(api, captured: captured).upload(
          dropId: 'd-1',
          password: 'pw',
          source: _MemorySource(plaintext),
          ownerIdentityPub: owner.identityPublic,
        );

        expect(captured, hasLength(1));
        final body = captured.single.bodyBytes;

        // Positive check: it is a real OS4S container, not merely
        // "different bytes".
        expect(
          body.sublist(0, 4),
          equals(FileCrypto.magicPrefix),
          reason: 'not an OS4S ciphertext container',
        );
        // Negative check: the plaintext does not survive anywhere in
        // it. Checking for a single BYTE value would be meaningless —
        // random ciphertext contains any given byte with near
        // certainty — so this looks for the string.
        expect(body, isNot(equals(plaintext)));
        expect(
          utf8.decode(body, allowMalformed: true),
          isNot(contains('PASSPORT NUMBER')),
        );
      });

      test('refuses a closed link without consuming a slot', () async {
        final api = _FakeApi();
        when(() => api.info(any())).thenAnswer(
          (_) async => const DropUploadInfo(
            open: false,
            maxBytes: 1024,
            passwordRequired: true,
          ),
        );
        await expectLater(
          build(api).upload(
            dropId: 'd-1',
            password: 'pw',
            source: _MemorySource(const [1, 2, 3]),
            ownerIdentityPub: owner.identityPublic,
          ),
          throwsA(isA<DropClosedException>()),
        );
        // /initiate reserves a slot whether or not the upload finishes,
        // so it must not be reached.
        verifyNever(
          () => api.initiate(
            dropId: any(named: 'dropId'),
            password: any(named: 'password'),
            byteCount: any(named: 'byteCount'),
          ),
        );
      });

      test('refuses an oversized file before consuming a slot', () async {
        final api = _FakeApi();
        stubOpen(api, maxBytes: 100);
        await expectLater(
          build(api).upload(
            dropId: 'd-1',
            password: 'pw',
            source: _MemorySource(List<int>.filled(5000, 1)),
            ownerIdentityPub: owner.identityPublic,
          ),
          throwsA(isA<DropFileTooLargeException>()),
        );
        verifyNever(
          () => api.initiate(
            dropId: any(named: 'dropId'),
            password: any(named: 'password'),
            byteCount: any(named: 'byteCount'),
          ),
        );
      });

      test('refuses to seal to an empty owner key', () async {
        // A link whose fragment was stripped. Sealing to nothing would
        // produce an upload nobody can open.
        final api = _FakeApi();
        stubOpen(api);
        await expectLater(
          build(api).upload(
            dropId: 'd-1',
            password: 'pw',
            source: _MemorySource(const [1]),
            ownerIdentityPub: Uint8List(0),
          ),
          throwsA(isA<ArgumentError>()),
        );
        verifyNever(() => api.info(any()));
      });
    },
    skip: skipReason,
  );
}
