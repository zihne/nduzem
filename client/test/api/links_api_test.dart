import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:nduzem/api/api_client.dart';
import 'package:nduzem/api/links_api.dart';

class _FakeClient extends Mock implements ApiClient {}

void main() {
  setUpAll(() => registerFallbackValue(<String, dynamic>{}));

  late _FakeClient client;
  late LinksApi api;

  setUp(() {
    client = _FakeClient();
    api = LinksApi(client);
  });

  group('LinksApi.info', () {
    test('unauthed GET decodes a downloadable link', () async {
      when(() => client.get(any())).thenAnswer(
        (_) async => <String, dynamic>{
          'transfer_id': 't-1',
          'exists': true,
          'expired': false,
          'consumed': false,
          'password_required': false,
          'enc_header': 'aGVsbG8=',
          'crypto_suite': 1,
          'byte_count': 4096,
          'expires_at': '2026-08-01T00:00:00+00:00',
        },
      );

      final info = await api.info('t-1');
      final path = verify(() => client.get(captureAny())).captured.single
          as String;
      expect(path, '/v1/links/t-1');
      expect(info.exists, isTrue);
      expect(info.downloadable, isTrue);
      expect(info.encHeaderB64, 'aGVsbG8=');
      expect(info.byteCount, 4096);
    });

    test('expired/consumed/absent shapes still decode', () async {
      when(() => client.get(any())).thenAnswer(
        (_) async => <String, dynamic>{
          'transfer_id': 't-x',
          'exists': false,
          'expired': false,
          'consumed': false,
          'password_required': false,
        },
      );
      final info = await api.info('t-x');
      expect(info.exists, isFalse);
      expect(info.downloadable, isFalse);
      expect(info.encHeaderB64, isNull);
    });
  });

  group('LinksApi.download', () {
    test('POSTs with password body when provided', () async {
      when(
        () => client.post(any(), body: any(named: 'body')),
      ).thenAnswer(
        (_) async => <String, dynamic>{
          'download_url': 'https://s3.example/get/x',
          'signature': 'c2ln',
          'blob_sha256': 'abcdef',
          'enc_header': 'aGRy',
          'crypto_suite': 1,
        },
      );

      final res = await api.download('t-1', password: 'hunter2');
      final captured = verify(
        () => client.post(captureAny(), body: captureAny(named: 'body')),
      ).captured;
      expect(captured[0] as String, '/v1/links/t-1/download');
      expect(
        captured[1] as Map<String, dynamic>,
        {'link_password': 'hunter2'},
      );
      expect(res.downloadUrl, startsWith('https://'));
      expect(res.blobSha256Hex, 'abcdef');
    });

    test('POSTs with an empty body when no password', () async {
      when(
        () => client.post(any(), body: any(named: 'body')),
      ).thenAnswer(
        (_) async => <String, dynamic>{
          'download_url': 'https://s3.example/get/y',
          'signature': 'c2ln',
          'blob_sha256': 'abcdef',
          'enc_header': 'aGRy',
          'crypto_suite': 1,
        },
      );
      await api.download('t-2');
      final captured = verify(
        () => client.post(captureAny(), body: captureAny(named: 'body')),
      ).captured;
      // No password field — server treats absence as "not supplied"
      // rather than "empty string." Important: an empty string could
      // pass through Argon2 verify_password if a broken sender
      // registered "" as the password.
      expect(captured[1] as Map<String, dynamic>, <String, dynamic>{});
    });
  });

  test('LinksApi.ack POSTs to /ack and returns status', () async {
    when(() => client.post(any())).thenAnswer(
      (_) async => <String, dynamic>{'status': 'deleted'},
    );
    final status = await api.ack('t-1');
    expect(status, 'deleted');
    verify(() => client.post('/v1/links/t-1/ack')).called(1);
  });
}
