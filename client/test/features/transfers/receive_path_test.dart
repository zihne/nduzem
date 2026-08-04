import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:opaqueshare/api/transfers_api.dart';
import 'package:opaqueshare/api/links_api.dart';
import 'package:opaqueshare/api/users_api.dart';
import 'package:opaqueshare/crypto/envelope.dart';
import 'package:opaqueshare/crypto/file_crypto.dart';
import 'package:opaqueshare/crypto/sealed_box.dart';
import 'package:opaqueshare/crypto/suite.dart';
import 'package:opaqueshare/crypto/suite_keys.dart';
import 'package:opaqueshare/features/transfers/transfer_service.dart';
import 'package:opaqueshare/storage/secure_storage.dart';
import 'package:sodium_libs/sodium_libs.dart';

import '../../crypto/sodium_test_support.dart';

/// End-to-end tests for `TransferService.receive`.
///
/// The gap this closes: the receive path had NO tests, so the wiring
/// between "read `crypto_suite` off the wire" and "derive subkeys with
/// it" was verified only by reading it. Mutating that dispatch to always
/// use suite 1 was caught by the analyzer and by nothing else.
///
/// Everything cryptographic here is REAL — real libsodium, real
/// `Envelope`, real `FileCrypto`, real `SealedBox`. The mocks only carry
/// bytes between them, so a passing test means the ciphertext actually
/// decrypted, not that a mock was called. A harness that asserted on
/// `verify(() => api.requestDownload(...))` would prove nothing about
/// the crypto and is exactly what this avoids.
class _FakeTransfers extends Mock implements TransfersApi {}

class _FakeLinks extends Mock implements LinksApi {}

class _FakeUsers extends Mock implements UsersApi {}

class _FakeStore extends Mock implements SecureStore {}

/// Serves the ciphertext for whatever URL the service asks for.
class _BlobClient extends http.BaseClient {
  _BlobClient(this.body);
  final List<int> body;
  int requests = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests++;
    return http.StreamedResponse(
      Stream<List<int>>.value(body),
      200,
      contentLength: body.length,
    );
  }
}

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();

  final maybeSodium = await tryInitSodium();
  final skipReason = sodiumSkipReason(maybeSodium);
  late final Sodium sodium;
  late final FileCrypto fc;
  late final Envelope env;
  late final SealedBox sealedBox;
  if (maybeSodium != null) {
    sodium = maybeSodium;
    fc = FileCrypto(sodium);
    env = Envelope(sodium);
    sealedBox = SealedBox(sodium);
  }

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('receive-test-');
    // `receive()` calls getTemporaryDirectory() directly; stand in for
    // the plugin the same way saf_saver_test does.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async =>
          call.method == 'getTemporaryDirectory' ? tempDir.path : null,
    );
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  /// Build a genuine app-mode envelope the way `send` does, and wire the
  /// fakes to serve it. Returns the assembled service plus the pieces a
  /// test may want to tamper with.
  Future<
      ({
        TransferService service,
        _FakeTransfers api,
        _BlobClient blob,
        Uint8List plaintext,
        String blobSha256,
        String encHeaderB64,
        String wrappedKeyB64,
        String signatureB64,
        Uint8List signingPub,
        Uint8List fileKey,
        Uint8List identityPriv,
        Uint8List identityPub,
      })> build({
    CryptoSuite suite = CryptoSuite.classicalSplitKeys,
    String filename = 'report.pdf',
  }) async {
    final recipient = sodium.crypto.box.keyPair();
    final signing = sodium.crypto.sign.keyPair();
    final identityPriv = recipient.secretKey.extractBytes();
    final signingPriv = signing.secretKey.extractBytes();
    recipient.secretKey.dispose();
    signing.secretKey.dispose();

    final fileKey = fc.generateFileKey();
    final keys = SuiteKeys.derive(sodium, fileKey, suite);
    final plain = Uint8List.fromList(
      List<int>.generate(FileCrypto.plaintextChunkBytes + 321, (i) => i & 0xff),
    );
    final ct = await fc.encryptFile(plaintext: plain, key: keys.bodyKey);
    final hash = fc.sha256Hex(ct);
    final encHeader = env.buildEncHeader(
      filename: filename,
      mime: 'application/pdf',
      plaintextLength: plain.length,
      blobSha256Hex: hash,
      fileKey: keys.headerKey,
    );
    final signature = env.signBlobSha256(
      blobSha256Hex: hash,
      signingPrivate: signingPriv,
    );
    final wrapped = sealedBox.seal(
      message: fileKey,
      recipientIdentityPublic: recipient.publicKey,
    );

    final api = _FakeTransfers();
    final store = _FakeStore();
    final blob = _BlobClient(ct);

    when(() => store.read(SecureStore.kUserId))
        .thenAnswer((_) async => 'user-1');
    when(() => store.readBytes(SecureStore.identityPrivateKeyFor('user-1')))
        .thenAnswer((_) async => identityPriv);
    when(() => store.readBytes(SecureStore.identityPublicKeyFor('user-1')))
        .thenAnswer((_) async => recipient.publicKey);

    when(() => api.requestDownload(any())).thenAnswer(
      (_) async => DownloadTransferResponse(
        downloadUrl: 'https://example.invalid/blob',
        wrappedKeyB64: base64Encode(wrapped),
        signatureB64: base64Encode(signature),
        blobSha256Hex: hash,
        encHeaderB64: base64Encode(encHeader),
        cryptoSuite: suite.wireValue,
        senderIdentityPubB64: base64Encode(recipient.publicKey),
        senderSigningPubB64: base64Encode(signing.publicKey),
        senderId: 'sender-1',
        senderHandle: 'alice',
      ),
    );

    final service = TransferService(
      transfers: api,
      links: _FakeLinks(),
      users: _FakeUsers(),
      sealedBox: sealedBox,
      fileCrypto: fc,
      envelope: env,
      storage: store,
      sodium: sodium,
      httpClient: blob,
    );
    return (
      service: service,
      api: api,
      blob: blob,
      plaintext: plain,
      blobSha256: hash,
      encHeaderB64: base64Encode(encHeader),
      wrappedKeyB64: base64Encode(wrapped),
      signatureB64: base64Encode(signature),
      signingPub: signing.publicKey,
      fileKey: fileKey,
      identityPriv: identityPriv,
      identityPub: recipient.publicKey,
    );
  }

  group(
    'receive',
    () {
      for (final suite in CryptoSuite.values) {
        test('suite ${suite.wireValue} decrypts to the original bytes',
            () async {
          // THE test that was missing. A dispatch bug — deriving with
          // the wrong suite — fails here and nowhere else.
          final t = await build(suite: suite);
          final got = await t.service.receive(transferId: 't-1');

          expect(got.filename, 'report.pdf');
          expect(got.plaintextLength, t.plaintext.length);
          final bytes = got.plaintextBytes ??
              await File(got.plaintextPath!).readAsBytes();
          expect(bytes, t.plaintext);
          expect(got.senderSignatureVerified, isTrue);
        });
      }

      test('an unknown crypto_suite is refused before anything decrypts',
          () async {
        final t2 = await build();
        when(() => t2.api.requestDownload(any())).thenAnswer(
          (_) async => DownloadTransferResponse(
            downloadUrl: 'https://example.invalid/blob',
            wrappedKeyB64: t2.wrappedKeyB64,
            signatureB64: t2.signatureB64,
            blobSha256Hex: t2.blobSha256,
            encHeaderB64: t2.encHeaderB64,
            cryptoSuite: 99,
            senderIdentityPubB64: null,
            senderSigningPubB64: null,
            senderId: null,
            senderHandle: null,
          ),
        );
        await expectLater(
          t2.service.receive(transferId: 't-1'),
          throwsA(isA<UnsupportedError>()),
        );
        expect(
          t2.blob.requests,
          0,
          reason: 'must fail closed BEFORE fetching the ciphertext',
        );
      });

      test('a header naming a different ciphertext is refused', () async {
        // Finding #2: `enc_header.blob_sha256` is sealed under K_file, so
        // it is the one hash a server cannot forge.
        //
        // Getting this test right is fiddly, and my first attempt was
        // wrong: reporting a hash matching nothing makes the DOWNLOAD's
        // own hash check fail first, so the test passed without ever
        // reaching the header check — deleting that check left it green.
        // The substituted blob must hash to exactly what the server
        // reports, so the header is the only thing that disagrees.
        final t = await build();
        final keys = SuiteKeys.derive(
          sodium,
          t.fileKey,
          CryptoSuite.classicalSplitKeys,
        );
        // SAME plaintext length as the original, different bytes. A
        // different length would be caught by the plaintext-length
        // guard instead — which also throws StateError, so the test
        // would pass with the header check deleted. Second time this
        // test passed for the wrong reason; the mutation is what found
        // it both times.
        final substituted = await fc.encryptFile(
          plaintext: Uint8List.fromList(
            List<int>.filled(t.plaintext.length, 7),
          ),
          key: keys.bodyKey,
        );
        final substitutedHash = fc.sha256Hex(substituted);
        expect(substitutedHash, isNot(t.blobSha256));

        final api = _FakeTransfers();
        final store = _FakeStore();
        when(() => store.read(SecureStore.kUserId))
            .thenAnswer((_) async => 'user-1');
        when(() => store.readBytes(SecureStore.identityPrivateKeyFor('user-1')))
            .thenAnswer((_) async => t.identityPriv);
        when(() => store.readBytes(SecureStore.identityPublicKeyFor('user-1')))
            .thenAnswer((_) async => t.identityPub);
        when(() => api.requestDownload(any())).thenAnswer(
          (_) async => DownloadTransferResponse(
            downloadUrl: 'https://example.invalid/blob',
            wrappedKeyB64: t.wrappedKeyB64,
            signatureB64: t.signatureB64,
            blobSha256Hex: substitutedHash,
            encHeaderB64: t.encHeaderB64,
            cryptoSuite: CryptoSuite.classicalSplitKeys.wireValue,
            senderIdentityPubB64: null,
            // No signing pub → the signature step is skipped, so the
            // header binding is the ONLY thing that can refuse this.
            senderSigningPubB64: null,
            senderId: null,
            senderHandle: null,
          ),
        );
        final service = TransferService(
          transfers: api,
          links: _FakeLinks(),
          users: _FakeUsers(),
          sealedBox: sealedBox,
          fileCrypto: fc,
          envelope: env,
          storage: store,
          sodium: sodium,
          httpClient: _BlobClient(substituted),
        );
        await expectLater(
          service.receive(transferId: 't-1'),
          throwsA(isA<StateError>()),
        );
      });

      test('a bad sender signature blocks the decrypt', () async {
        final t = await build();
        when(() => t.api.requestDownload(any())).thenAnswer(
          (_) async => DownloadTransferResponse(
            downloadUrl: 'https://example.invalid/blob',
            wrappedKeyB64: t.wrappedKeyB64,
            signatureB64: base64Encode(Uint8List(64)), // all zeroes
            blobSha256Hex: t.blobSha256,
            encHeaderB64: t.encHeaderB64,
            cryptoSuite: CryptoSuite.classicalSplitKeys.wireValue,
            senderIdentityPubB64: null,
            senderSigningPubB64: base64Encode(t.signingPub),
            senderId: null,
            senderHandle: null,
          ),
        );
        await expectLater(
          t.service.receive(transferId: 't-1'),
          throwsA(isA<StateError>()),
        );
      });

      test('the ciphertext temp does not survive a successful receive',
          () async {
        final t = await build();
        await t.service.receive(transferId: 't-1');
        final leftovers = tempDir
            .listSync()
            .whereType<File>()
            .map((f) => f.uri.pathSegments.last)
            .where((n) => n.endsWith('.ct.tmp'))
            .toList();
        expect(
          leftovers,
          isEmpty,
          reason: 'ciphertext temp must be deleted after decrypt',
        );
      });
    },
    skip: skipReason,
  );
}
