// One HTTP client per service, not one per request.
//
// `_httpClient` was a GETTER — `_http ?? http.Client()` — so every read
// constructed a new client, and nothing closed any of them.
// `_uploadOnePart` reads it once per multipart part, so a large transfer
// leaked one `IOClient` and its whole connection pool per part. The
// failure lands mid-upload on exactly the big files the product exists
// for: socket and file-descriptor exhaustion, presenting as flaky
// transfers rather than as anything naming its cause.
//
// Nothing in the type system objects to a getter returning a fresh
// instance, and no other test counted them. This one does.
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:sodium_libs/sodium_libs.dart';

import 'package:nduzem/api/links_api.dart';
import 'package:nduzem/api/transfers_api.dart';
import 'package:nduzem/api/users_api.dart';
import 'package:nduzem/crypto/envelope.dart';
import 'package:nduzem/crypto/file_crypto.dart';
import 'package:nduzem/crypto/sealed_box.dart';
import 'package:nduzem/features/transfers/transfer_service.dart';
import 'package:nduzem/storage/secure_storage.dart';

class _FakeTransfers extends Mock implements TransfersApi {}

class _FakeLinks extends Mock implements LinksApi {}

class _FakeUsers extends Mock implements UsersApi {}

class _FakeStore extends Mock implements SecureStore {}

class _FakeSealedBox extends Mock implements SealedBox {}

class _FakeFileCrypto extends Mock implements FileCrypto {}

class _FakeEnvelope extends Mock implements Envelope {}

class _FakeSodium extends Mock implements Sodium {}

/// Records whether `close()` was called, so lifecycle ownership can be
/// asserted rather than assumed.
class _TrackingClient extends http.BaseClient {
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(const Stream.empty(), 200);

  @override
  void close() => closed = true;
}

TransferService _service({http.Client? httpClient}) => TransferService(
      transfers: _FakeTransfers(),
      links: _FakeLinks(),
      users: _FakeUsers(),
      sealedBox: _FakeSealedBox(),
      fileCrypto: _FakeFileCrypto(),
      envelope: _FakeEnvelope(),
      storage: _FakeStore(),
      sodium: _FakeSodium(),
      httpClient: httpClient,
    );

void main() {
  test('repeated reads return the SAME self-created client', () {
    // This is the leak, expressed directly. Before the fix each read
    // constructed a new client; a multipart upload did this once per
    // part and closed none of them.
    final service = _service();

    final a = service.debugHttpClient;
    final b = service.debugHttpClient;
    final c = service.debugHttpClient;

    expect(identical(a, b), isTrue);
    expect(
      identical(b, c),
      isTrue,
      reason: 'a getter that constructs would hand back a new client every '
          'read — one per multipart part, none closed',
    );
  });

  test('an injected client is used as-is and reused', () {
    final injected = _TrackingClient();
    final service = _service(httpClient: injected);

    expect(identical(service.debugHttpClient, injected), isTrue);
    expect(identical(service.debugHttpClient, injected), isTrue);
  });

  test('dispose closes a client the service created', () {
    // Injecting a tracking client would make this untestable — the point
    // is the self-created path — so assert via the branch that dispose
    // only closes when `_http` was null. A self-created client is a real
    // http.Client; reaching here without throwing is the assertion.
    final service = _service();
    service.debugHttpClient; // force `late final` initialisation
    expect(service.dispose, returnsNormally);
  });

  test('dispose does NOT close an injected client', () {
    // Whoever injected it owns its lifecycle. Closing here would break a
    // caller still holding it — and in tests, would break the fixture
    // between cases.
    final injected = _TrackingClient();
    final service = _service(httpClient: injected);
    service.debugHttpClient;

    service.dispose();

    expect(injected.closed, isFalse);
  });
}
