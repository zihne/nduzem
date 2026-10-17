import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:sodium_libs/sodium_libs.dart';

import '../../api/api_client.dart';
import '../../api/drop_uploads_api.dart';
import '../../crypto/envelope.dart';
import '../../crypto/file_crypto.dart';
import '../../crypto/keys.dart';
import '../../crypto/plaintext_source.dart';
import '../../crypto/sealed_box.dart';
import '../../crypto/suite.dart';
import '../../crypto/suite_keys.dart';

/// Encrypting and uploading a file through someone else's drop link
/// (ADR-0040 phase 4b). The uploader has no account.
///
/// Separated from the screen so the part that matters is testable
/// without a browser. The UI around it is a password box and a file
/// picker; everything that could be *wrong* is here.
///
/// WHAT MAKES THIS DIFFERENT FROM A NORMAL SEND
///
/// 1. The recipient's key comes from the URL fragment, handed in as
///    [ownerIdentityPub]. It is NOT fetched from the API, so a
///    compromised server cannot substitute its own and read the upload.
///    The caller is responsible for taking it from `#k=` and nowhere
///    else.
/// 2. The sender keypair is **generated here, per upload, and
///    discarded**. There is no account to sign with.
/// 3. Therefore the signature proves only that whoever encrypted the
///    file also signed it. It is an integrity binding, not an identity.
///    The owner cannot learn who uploaded, ever.
///
/// Reusing [FileCrypto], [Envelope], [SealedBox] and [SuiteKeys] rather
/// than reimplementing the sealing step is deliberate: a second
/// implementation of this is where a silent incompatibility or a real
/// cryptographic mistake would live, and it would sit outside the code
/// anyone can read.
class DropUploadService {
  DropUploadService({
    required DropUploadsApi api,
    required Sodium sodium,
    required FileCrypto fileCrypto,
    required Envelope envelope,
    required KeypairGenerator keys,
    http.Client? httpClient,
  })  : _api = api,
        _sodium = sodium,
        _fileCrypto = fileCrypto,
        _envelope = envelope,
        _keys = keys,
        _http = httpClient ?? http.Client();

  final DropUploadsApi _api;
  final Sodium _sodium;
  final FileCrypto _fileCrypto;
  final Envelope _envelope;
  final KeypairGenerator _keys;
  final http.Client _http;

  Future<DropUploadInfo> info(String dropId) => _api.info(dropId);

  /// Encrypt [source] and upload it through [dropId].
  ///
  /// [ownerIdentityPub] is the owner's X25519 public key, taken from the
  /// link fragment. Throws [ArgumentError] if it is empty rather than
  /// sealing to nothing.
  /// [knownInfo] lets a multi-file submission share one `GET /info`
  /// across all its files. Without it this method fetches info per
  /// file, which for ten files is ten calls against a bucket of ten —
  /// so the eleventh file failed on a rate limit rather than on
  /// anything about the file, and said so unhelpfully.
  ///
  /// Still fetched when absent: a single-file caller should not have to
  /// know to pass it, and the check has to happen before `/initiate`
  /// spends one of the owner's slots.
  Future<DropUploadResult> upload({
    required String dropId,
    required String password,
    required PlaintextSource source,
    required Uint8List ownerIdentityPub,
    DropUploadInfo? knownInfo,
    void Function(DropUploadPhase phase, int done, int total)? onProgress,
  }) async {
    if (ownerIdentityPub.isEmpty) {
      throw ArgumentError.value(
        ownerIdentityPub,
        'ownerIdentityPub',
        'the owner key from the link fragment is required; without it '
            'there is nobody to seal the file to',
      );
    }

    // Fail before consuming one of the owner's upload slots. /initiate
    // reserves a slot whether or not the upload completes, so a size
    // check afterwards would cost them an allowance for a file that was
    // never going to be accepted.
    final info = knownInfo ?? await _api.info(dropId);
    if (!info.open) {
      throw const DropClosedException();
    }
    final estimated = _fileCrypto.estimateCiphertextLength(source.lengthBytes);
    if (estimated > info.maxBytes) {
      throw DropFileTooLargeException(
        fileBytes: source.lengthBytes,
        maxBytes: info.maxBytes,
      );
    }

    // One keypair, this upload only. Never stored, never reused.
    final ephemeral = _keys.generate();

    // K_file, and the suite's derived header/body keys.
    final fileKey = _fileCrypto.generateFileKey();
    const suite = CryptoSuite.classical;
    final suiteKeys = SuiteKeys.derive(_sodium, fileKey, suite);

    // Sealed to the key from the FRAGMENT. This single line is why the
    // server cannot read the upload.
    final wrappedKey = SealedBox(_sodium).seal(
      message: fileKey,
      recipientIdentityPublic: ownerIdentityPub,
    );

    final ticket = await _api.initiate(
      dropId: dropId,
      password: password,
      byteCount: estimated,
    );

    final handle = _fileCrypto.encryptToStream(
      source: source,
      key: suiteKeys.bodyKey,
      onProgress: (d, t) => onProgress?.call(DropUploadPhase.encrypting, d, t),
    );

    // Single PUT. A drop is for a document, and the server's own cap
    // keeps these well under the multipart threshold — adding a second
    // upload path here would double the surface for no case anyone has
    // asked for.
    final buffer = BytesBuilder(copy: false);
    await for (final chunk in handle.stream) {
      buffer.add(chunk);
    }
    final body = buffer.takeBytes();
    onProgress?.call(DropUploadPhase.uploading, 0, body.length);
    final res = await _http.put(Uri.parse(ticket.uploadUrl), body: body);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw ApiException(
        statusCode: res.statusCode,
        message: 'Upload to storage failed (HTTP ${res.statusCode}).',
      );
    }
    onProgress?.call(DropUploadPhase.uploading, body.length, body.length);

    final summary = await handle.done;
    final encHeader = _envelope.buildEncHeader(
      filename: source.filename,
      mime: source.mimeType,
      plaintextLength: source.lengthBytes,
      blobSha256Hex: summary.blobSha256Hex,
      fileKey: suiteKeys.headerKey,
    );
    final signature = _envelope.signBlobSha256(
      blobSha256Hex: summary.blobSha256Hex,
      signingPrivate: ephemeral.signingPrivate,
    );

    final stored = await _api.commit(
      dropId: dropId,
      password: password,
      transferId: ticket.transferId,
      blobSha256Hex: summary.blobSha256Hex,
      encHeaderB64: base64Encode(encHeader),
      signatureB64: base64Encode(signature),
      wrappedKeyB64: base64Encode(wrappedKey),
      senderIdentityPubB64: ephemeral.identityPublicB64,
      senderSigningPubB64: ephemeral.signingPublicB64,
      cryptoSuite: suite.wireValue,
    );
    onProgress?.call(DropUploadPhase.done, stored, stored);
    return DropUploadResult(transferId: ticket.transferId, byteCount: stored);
  }
}

enum DropUploadPhase { encrypting, uploading, done }

class DropUploadResult {
  const DropUploadResult({required this.transferId, required this.byteCount});
  final String transferId;
  final int byteCount;
}

/// The link is not accepting files. **Carries no reason**, because the
/// server does not supply one: revoked, expired, full, blocked owner and
/// never-existed are one answer by design.
class DropClosedException implements Exception {
  const DropClosedException();
  @override
  String toString() => 'DropClosedException';
}

class DropFileTooLargeException implements Exception {
  const DropFileTooLargeException({
    required this.fileBytes,
    required this.maxBytes,
  });
  final int fileBytes;
  final int maxBytes;
  @override
  String toString() =>
      'DropFileTooLargeException(file=$fileBytes, max=$maxBytes)';
}
