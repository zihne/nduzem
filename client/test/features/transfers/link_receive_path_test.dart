import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:opaqueshare/api/links_api.dart';
import 'package:opaqueshare/api/transfers_api.dart';
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

/// End-to-end tests for `TransferService.receiveLinkMode`.
///
/// Link mode's trust model differs from app mode in one way that matters
/// for what these tests can assert:
///
///   * There is no sender identity, so the Ed25519 signature travels but
///     is never verified (ADR-0010, and the comment on
///     `LinkDownload.signatureB64`).
///   * K_file rides in the URL fragment and NEVER reaches the server.
///
/// The second fact is what makes the first tolerable. Because the server
/// never holds K_file, it cannot forge `enc_header` — so the check that
/// `enc_header.blob_sha256` agrees with the hash the server reported is
/// not merely defence-in-depth here, as it is in app mode. It is the
/// only thing binding the delivered ciphertext to what the sender
/// actually sealed. A test below pins that.
///
/// As in the app-mode harness, all crypto is real; the mocks only carry
/// bytes.
class _FakeLinks extends Mock implements LinksApi {}

class _FakeTransfers extends Mock implements TransfersApi {}

class _FakeUsers extends Mock implements UsersApi {}

class _FakeStore extends Mock implements SecureStore {}

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
    tempDir = await Directory.systemTemp.createTemp('link-receive-test-');
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

  /// Seal a link-mode envelope the way the sender does, and wire the
  /// fakes to serve it back.
  Future<
      ({
        TransferService service,
        _FakeLinks api,
        _BlobClient blob,
        Uint8List plaintext,
        Uint8List fileKey,
        String blobSha256,
        String encHeaderB64,
      })> build({
    CryptoSuite suite = CryptoSuite.classicalSplitKeys,
    String filename = 'contract.pdf',
  }) async {
    final fileKey = fc.generateFileKey();
    final keys = SuiteKeys.derive(sodium, fileKey, suite);
    final plain = Uint8List.fromList(
      List<int>.generate(FileCrypto.plaintextChunkBytes + 99, (i) => i & 0xff),
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

    final api = _FakeLinks();
    final blob = _BlobClient(ct);
    when(() => api.download(any(), password: any(named: 'password')))
        .thenAnswer(
      (_) async => LinkDownload(
        downloadUrl: 'https://example.invalid/blob',
        signatureB64: base64Encode(Uint8List(64)),
        blobSha256Hex: hash,
        encHeaderB64: base64Encode(encHeader),
        cryptoSuite: suite.wireValue,
      ),
    );

    final service = TransferService(
      transfers: _FakeTransfers(),
      links: api,
      users: _FakeUsers(),
      sealedBox: sealedBox,
      fileCrypto: fc,
      envelope: env,
      storage: _FakeStore(),
      sodium: sodium,
      httpClient: blob,
    );
    return (
      service: service,
      api: api,
      blob: blob,
      plaintext: plain,
      fileKey: fileKey,
      blobSha256: hash,
      encHeaderB64: base64Encode(encHeader),
    );
  }

  group(
    'receiveLinkMode',
    () {
      for (final suite in CryptoSuite.values) {
        test('suite ${suite.wireValue} decrypts with the fragment key',
            () async {
          final t = await build(suite: suite);
          final got = await t.service.receiveLinkMode(
            transferId: 'link-1',
            fileKey: t.fileKey,
          );
          expect(got.filename, 'contract.pdf');
          expect(got.plaintextLength, t.plaintext.length);
          final bytes = got.plaintextBytes ??
              await File(got.plaintextPath!).readAsBytes();
          expect(bytes, t.plaintext);
        });
      }

      test('the wrong fragment key cannot open the envelope', () async {
        // Possession of K_file IS the credential in link mode — the
        // server never sees it. A link without the fragment, or with a
        // truncated one, must fail rather than half-open.
        final t = await build();
        final wrong = fc.generateFileKey();
        await expectLater(
          t.service.receiveLinkMode(transferId: 'link-1', fileKey: wrong),
          throwsA(anything),
        );
      });

      test('an unknown crypto_suite is refused before the blob is fetched',
          () async {
        final t = await build();
        when(
          () => t.api.download(any(), password: any(named: 'password')),
        ).thenAnswer(
          (_) async => LinkDownload(
            downloadUrl: 'https://example.invalid/blob',
            signatureB64: base64Encode(Uint8List(64)),
            blobSha256Hex: t.blobSha256,
            encHeaderB64: t.encHeaderB64,
            cryptoSuite: 99,
          ),
        );
        await expectLater(
          t.service.receiveLinkMode(transferId: 'link-1', fileKey: t.fileKey),
          throwsA(isA<UnsupportedError>()),
        );
        expect(
          t.blob.requests,
          0,
          reason: 'must fail closed BEFORE fetching ciphertext',
        );
      });

      test('a substituted ciphertext is refused by the header binding',
          () async {
        // THE link-mode security property. There is no signature check
        // here (ADR-0010), so this is the ONLY thing tying the delivered
        // bytes to what the sender sealed — and it holds because the
        // server never has K_file and therefore cannot forge the header.
        //
        // Same length as the original so the plaintext-length guard
        // cannot be what catches it; the header hash must be.
        final t = await build();
        final keys = SuiteKeys.derive(
          sodium,
          t.fileKey,
          CryptoSuite.classicalSplitKeys,
        );
        final substituted = await fc.encryptFile(
          plaintext: Uint8List.fromList(
            List<int>.filled(t.plaintext.length, 7),
          ),
          key: keys.bodyKey,
        );
        final substitutedHash = fc.sha256Hex(substituted);
        expect(substitutedHash, isNot(t.blobSha256));

        final api = _FakeLinks();
        when(
          () => api.download(any(), password: any(named: 'password')),
        ).thenAnswer(
          (_) async => LinkDownload(
            downloadUrl: 'https://example.invalid/blob',
            signatureB64: base64Encode(Uint8List(64)),
            // Matches the blob actually served, so the download's own
            // hash check passes and only the header disagrees.
            blobSha256Hex: substitutedHash,
            encHeaderB64: t.encHeaderB64,
            cryptoSuite: CryptoSuite.classicalSplitKeys.wireValue,
          ),
        );
        final service = TransferService(
          transfers: _FakeTransfers(),
          links: api,
          users: _FakeUsers(),
          sealedBox: sealedBox,
          fileCrypto: fc,
          envelope: env,
          storage: _FakeStore(),
          sodium: sodium,
          httpClient: _BlobClient(substituted),
        );
        await expectLater(
          service.receiveLinkMode(transferId: 'link-1', fileKey: t.fileKey),
          throwsA(isA<StateError>()),
        );
      });

      test('the link password is passed through to the API', () async {
        final t = await build();
        await t.service.receiveLinkMode(
          transferId: 'link-1',
          fileKey: t.fileKey,
          password: 'hunter2',
        );
        verify(() => t.api.download('link-1', password: 'hunter2')).called(1);
      });

      test('the ciphertext temp does not survive a successful receive',
          () async {
        final t = await build();
        await t.service.receiveLinkMode(
          transferId: 'link-1',
          fileKey: t.fileKey,
        );
        final leftovers = tempDir
            .listSync()
            .whereType<File>()
            .map((f) => f.uri.pathSegments.last)
            .where((n) => n.endsWith('.ct.tmp'))
            .toList();
        expect(leftovers, isEmpty);
      });
    },
    skip: skipReason,
  );
}
