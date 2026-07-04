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
        mode: 'app',
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

    test('single-shot response leaves multipart null (ADR-0003)', () async {
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
        mode: 'app',
        recipientId: 'u-42',
        byteCount: 1024,
        blobSha256Hex: 'a' * 64,
        wrappedKeyB64: 'WK',
        encHeaderB64: 'EH',
        signatureB64: 'SIG',
      );
      expect(res.uploadUrl, isNotNull);
      expect(res.multipart, isNull);
    });

    test('multipart response decodes upload_id + parts (ADR-0003)', () async {
      when(
        () => client.post(any(), body: any(named: 'body'), authed: any(named: 'authed')),
      ).thenAnswer(
        (_) async => <String, dynamic>{
          'transfer_id': 't-2',
          'storage_key': 'obj/xyz',
          'multipart': {
            'upload_id': 'mp-1',
            'part_size': 8388608,
            'parts': [
              {'part_number': 1, 'url': 'https://r2.example/put/1'},
              {'part_number': 2, 'url': 'https://r2.example/put/2'},
            ],
          },
        },
      );
      final res = await api.initiate(
        mode: 'app',
        recipientId: 'u-42',
        byteCount: 12000000,
        blobSha256Hex: 'b' * 64,
        wrappedKeyB64: 'WK',
        encHeaderB64: 'EH',
        signatureB64: 'SIG',
      );
      expect(res.uploadUrl, isNull);
      expect(res.multipart, isNotNull);
      expect(res.multipart!.uploadId, 'mp-1');
      expect(res.multipart!.partSize, 8388608);
      expect(res.multipart!.parts, hasLength(2));
      expect(res.multipart!.parts[0].partNumber, 1);
      expect(res.multipart!.parts[1].url, 'https://r2.example/put/2');
    });

    test('link-mode envelope omits recipient_id + wrapped_key (ADR-0005)',
        () async {
      when(
        () => client.post(
          any(),
          body: any(named: 'body'),
          authed: any(named: 'authed'),
        ),
      ).thenAnswer(
        (_) async => <String, dynamic>{
          'transfer_id': 't-link',
          'storage_key': 'obj/link',
          'upload_url': 'https://r2.example/put',
        },
      );

      await api.initiate(
        mode: 'link',
        byteCount: 1024,
        blobSha256Hex: 'c' * 64,
        encHeaderB64: 'EH',
        signatureB64: 'SIG',
        linkPassword: 'hunter2',
        maxDownloads: 3,
      );

      final captured = verify(
        () => client.post(
          '/v1/transfers/initiate',
          body: captureAny(named: 'body'),
          authed: any(named: 'authed'),
        ),
      ).captured.single as Map<String, dynamic>;
      expect(captured['mode'], 'link');
      expect(captured['link_password'], 'hunter2');
      expect(captured['max_downloads'], 3);
      // Server treats missing recipient_id / wrapped_key as
      // "link-mode is not sealed to anyone" — critical for the mode
      // dispatch to work, so we assert absence explicitly.
      expect(captured.containsKey('recipient_id'), isFalse);
      expect(captured.containsKey('wrapped_key'), isFalse);
      expect(captured.containsKey('recipient_email'), isFalse);
    });

    test('link-mode without password omits the field entirely', () async {
      when(
        () => client.post(
          any(),
          body: any(named: 'body'),
          authed: any(named: 'authed'),
        ),
      ).thenAnswer(
        (_) async => <String, dynamic>{
          'transfer_id': 't-link-nopwd',
          'storage_key': 'obj/link',
          'upload_url': 'https://r2.example/put',
        },
      );

      await api.initiate(
        mode: 'link',
        byteCount: 1024,
        blobSha256Hex: 'c' * 64,
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
      expect(captured['mode'], 'link');
      // Omitting the key altogether — the server's Pydantic model
      // treats missing vs null differently for the mode-validation
      // check, so we do NOT want `link_password: null` on the wire.
      expect(captured.containsKey('link_password'), isFalse);
    });
  });

  group('/v1/transfers/{id}/commit', () {
    test('single-shot commit sends no body (M2 wire compat)', () async {
      when(
        () => client.post(
          any(),
          body: any(named: 'body'),
          authed: any(named: 'authed'),
        ),
      ).thenAnswer(
        (_) async => <String, dynamic>{'status': 'uploaded', 'byte_count': 1024},
      );
      await api.commit('t-1');
      final captured = verify(
        () => client.post(
          '/v1/transfers/t-1/commit',
          body: captureAny(named: 'body'),
          authed: any(named: 'authed'),
        ),
      ).captured.single;
      expect(captured, isNull);
    });

    test('multipart commit sends parts list with ETags', () async {
      when(
        () => client.post(
          any(),
          body: any(named: 'body'),
          authed: any(named: 'authed'),
        ),
      ).thenAnswer(
        (_) async =>
            <String, dynamic>{'status': 'uploaded', 'byte_count': 12000000},
      );
      await api.commit(
        't-2',
        parts: const [
          CommitPart(partNumber: 1, etag: 'aaaa'),
          CommitPart(partNumber: 2, etag: 'bbbb'),
        ],
      );
      final captured = verify(
        () => client.post(
          '/v1/transfers/t-2/commit',
          body: captureAny(named: 'body'),
          authed: any(named: 'authed'),
        ),
      ).captured.single as Map<String, dynamic>;
      expect(captured['parts'], hasLength(2));
      expect((captured['parts'] as List)[0], {'part_number': 1, 'etag': 'aaaa'});
      expect((captured['parts'] as List)[1], {'part_number': 2, 'etag': 'bbbb'});
    });
  });

  group('/v1/transfers/{id}/abort', () {
    test('POSTs the abort endpoint (idempotent per ADR-0012)', () async {
      when(
        () => client.post(any(), authed: any(named: 'authed')),
      ).thenAnswer((_) async => <String, dynamic>{});
      await api.abort('t-3');
      verify(
        () => client.post(
          '/v1/transfers/t-3/abort',
          authed: any(named: 'authed'),
        ),
      ).called(1);
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
      // Sender pubkeys are optional (see ADR-0031) — absent in this
      // response means the receive path can't verify the signature.
      expect(dl.senderIdentityPubB64, isNull);
      expect(dl.senderSigningPubB64, isNull);
    });

    test('captures sender pubkeys when present (ADR-0031)', () async {
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
          'sender_identity_pub': 'SENDER_ID_PUB_B64',
          'sender_signing_pub': 'SENDER_SIGN_PUB_B64',
        },
      );
      final dl = await api.requestDownload('t-1');
      expect(dl.senderIdentityPubB64, 'SENDER_ID_PUB_B64');
      expect(dl.senderSigningPubB64, 'SENDER_SIGN_PUB_B64');
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
