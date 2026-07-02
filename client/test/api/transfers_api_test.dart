import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:opaqueshare/api/api_client.dart';
import 'package:opaqueshare/api/transfers_api.dart';

class _FakeClient extends Mock implements ApiClient {}

void main() {
  setUpAll(() => registerFallbackValue(<String, dynamic>{}));

  late _FakeClient client;
  late TransfersApi api;

  setUp(() {
    client = _FakeClient();
    api = TransfersApi(client);
  });

  group('/v1/transfers/initiate', () {
    test('posts the app-mode envelope shape', () async {
      when(
        () => client.post(any(), body: any(named: 'body'), authed: any(named: 'authed')),
      ).thenAnswer(
        (_) async => <String, dynamic>{
          'transfer_id': 't-1',
          'storage_key': 'obj/abc',
          'upload_url': 'https://r2.example/put',
        },
      );

      final res = await api.initiate(
        recipientId: 'u-42',
        byteCount: 1024,
        blobSha256Hex: 'a' * 64,
        wrappedKeyB64: 'WK',
        encHeaderB64: 'EH',
        signatureB64: 'SIG',
      );

      final captured = verify(
        () => client.post(
          '/v1/transfers/initiate',
          body: captureAny(named: 'body'),
          authed: any(named: 'authed'),
        ),
      ).captured.single as Map<String, dynamic>;
      expect(captured['mode'], 'app');
      expect(captured['recipient_id'], 'u-42');
      expect(captured['byte_count'], 1024);
      expect(captured['blob_sha256'], 'a' * 64);
      expect(captured['wrapped_key'], 'WK');
      expect(captured['enc_header'], 'EH');
      expect(captured['signature'], 'SIG');
      expect(captured['crypto_suite'], 1);
      expect(captured['max_downloads'], 1);
      expect(res.transferId, 't-1');
      expect(res.storageKey, 'obj/abc');
      expect(res.uploadUrl, startsWith('https://'));
    });

    test('rejects multipart responses in M2', () async {
      when(
        () => client.post(any(), body: any(named: 'body'), authed: any(named: 'authed')),
      ).thenAnswer(
        (_) async => <String, dynamic>{
          'transfer_id': 't-2',
          'storage_key': 'obj/xyz',
          'multipart': {
            'upload_id': 'mp-1',
            'part_size': 8,
            'parts': <Map<String, dynamic>>[],
          },
        },
      );

      expect(
        () => api.initiate(
          recipientId: 'u-42',
          byteCount: 999999999,
          blobSha256Hex: 'b' * 64,
          wrappedKeyB64: 'WK',
          encHeaderB64: 'EH',
          signatureB64: 'SIG',
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('/v1/transfers/inbox', () {
    test('extracts the JSON array from the ApiClient raw wrapper', () async {
      when(() => client.get(any(), authed: any(named: 'authed'))).thenAnswer(
        (_) async => <String, dynamic>{
          'raw': [
            {
              'transfer_id': 't-a',
              'sender_id': 'u-1',
              'sender_handle': 'alice',
              'enc_header': 'EH',
              'crypto_suite': 1,
              'byte_count': 128,
              'created_at': '2026-07-01T12:00:00Z',
              'expires_at': '2026-07-08T12:00:00Z',
            },
          ],
        },
      );

      final items = await api.inbox();
      expect(items, hasLength(1));
      expect(items.single.transferId, 't-a');
      expect(items.single.senderHandle, 'alice');
      expect(items.single.byteCount, 128);
    });
  });

  group('/v1/transfers/{id}/download', () {
    test('decodes envelope fields verbatim', () async {
      when(
        () => client.post(any(), body: any(named: 'body'), authed: any(named: 'authed')),
      ).thenAnswer(
        (_) async => <String, dynamic>{
          'download_url': 'https://r2.example/get',
          'wrapped_key': 'WK',
          'signature': 'SIG',
          'blob_sha256': 'a' * 64,
          'enc_header': 'EH',
          'crypto_suite': 1,
        },
      );
      final dl = await api.requestDownload('t-1');
      expect(dl.wrappedKeyB64, 'WK');
      expect(dl.blobSha256Hex, 'a' * 64);
    });
  });

  group('/v1/transfers/{id}/ack', () {
    test('posts and returns status', () async {
      when(
        () => client.post(any(), body: any(named: 'body'), authed: any(named: 'authed')),
      ).thenAnswer(
        (_) async => <String, dynamic>{'status': 'deleted'},
      );
      final status = await api.ack('t-1');
      expect(status, 'deleted');
      verify(
        () => client.post(
          '/v1/transfers/t-1/ack',
          authed: any(named: 'authed'),
        ),
      ).called(1);
    });
  });
}
