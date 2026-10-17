import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:nduzem/api/api_client.dart';
import 'package:nduzem/api/drops_api.dart';

class _FakeClient extends Mock implements ApiClient {}

void main() {
  setUpAll(() => registerFallbackValue(<String, dynamic>{}));

  late _FakeClient client;
  late DropsApi api;

  setUp(() {
    client = _FakeClient();
    api = DropsApi(client);
  });

  group('DropsApi.create', () {
    // The exact wire shape of DropCreateResponse. Hand-written key
    // mapping is where a typo hides silently, so this payload mirrors
    // the server schema field for field.
    final created = <String, dynamic>{
      'drop_id': 'd-1',
      'label': 'Smith matter',
      'password': 'K7M2-PQRX-39TB',
      'max_uploads': 10,
      'max_bytes': 2147483648,
      'expires_at': '2026-11-15T09:00:00Z',
      'created_at': '2026-10-16T09:00:00Z',
    };

    test('decodes the one-time password and the limits', () async {
      when(() => client.post(any(), body: any(named: 'body'), authed: true))
          .thenAnswer((_) async => created);

      final out = await api.create(label: 'Smith matter');

      expect(out.dropId, 'd-1');
      expect(out.password, 'K7M2-PQRX-39TB');
      expect(out.maxUploads, 10);
      expect(out.maxBytes, 2147483648);
      expect(out.expiresAt.toUtc().month, 11);
    });

    test('is authenticated and omits unset limits', () async {
      when(() => client.post(any(), body: any(named: 'body'), authed: true))
          .thenAnswer((_) async => created);

      await api.create(label: 'x');

      final sent = verify(
        () => client.post(
          captureAny(),
          body: captureAny(named: 'body'),
          authed: true,
        ),
      ).captured;
      expect(sent[0], '/v1/drops');
      final body = sent[1] as Map<String, dynamic>;
      // Absent, not null: the server applies its own defaults, and
      // sending explicit nulls would fail validation.
      expect(body.keys, ['label']);
    });

    test('sends the limits when they are given', () async {
      when(() => client.post(any(), body: any(named: 'body'), authed: true))
          .thenAnswer((_) async => created);

      await api.create(
        label: 'x',
        maxUploads: 3,
        maxBytes: 1024,
        expiresInDays: 7,
      );
      final body = verify(
        () => client.post(
          any(),
          body: captureAny(named: 'body'),
          authed: true,
        ),
      ).captured.single as Map<String, dynamic>;
      expect(body['max_uploads'], 3);
      expect(body['max_bytes'], 1024);
      expect(body['expires_in_days'], 7);
    });
  });

  group('DropsApi.list', () {
    test('decodes every state the server can report', () async {
      when(() => client.get(any(), authed: true)).thenAnswer(
        (_) async => <String, dynamic>{
          'items': [
            {
              'drop_id': 'd-open',
              'label': 'open one',
              'state': 'open',
              'uploads_used': 1,
              'max_uploads': 10,
              'max_bytes': 100,
              'expires_at': '2026-11-15T09:00:00Z',
              'revoked_at': null,
              'created_at': '2026-10-16T09:00:00Z',
            },
            {
              'drop_id': 'd-rev',
              'label': 'closed one',
              'state': 'revoked',
              'uploads_used': 0,
              'max_uploads': 10,
              'max_bytes': 100,
              'expires_at': '2026-11-15T09:00:00Z',
              'revoked_at': '2026-10-16T10:00:00Z',
              'created_at': '2026-10-16T09:00:00Z',
            },
            {
              'drop_id': 'd-exp',
              'label': 'expired one',
              'state': 'expired',
              'uploads_used': 2,
              'max_uploads': 10,
              'max_bytes': 100,
              'expires_at': '2026-10-01T09:00:00Z',
              'revoked_at': null,
              'created_at': '2026-09-01T09:00:00Z',
            },
            {
              'drop_id': 'd-full',
              'label': 'full one',
              'state': 'full',
              'uploads_used': 10,
              'max_uploads': 10,
              'max_bytes': 100,
              'expires_at': '2026-11-15T09:00:00Z',
              'revoked_at': null,
              'created_at': '2026-10-16T09:00:00Z',
            },
          ],
        },
      );

      final rows = await api.list();
      expect(rows.map((r) => r.state).toList(), [
        DropState.open,
        DropState.revoked,
        DropState.expired,
        DropState.full,
      ]);
      expect(rows.first.isOpen, isTrue);
      expect(rows[1].isOpen, isFalse);
      expect(rows[1].revokedAt, isNotNull);
      expect(rows.last.uploadsUsed, 10);
    });

    test('an unrecognised state degrades instead of throwing', () async {
      // A server that grows a fifth state must not crash an older
      // client — the list is the owner's only view of their drops.
      when(() => client.get(any(), authed: true)).thenAnswer(
        (_) async => <String, dynamic>{
          'items': [
            {
              'drop_id': 'd',
              'label': 'l',
              'state': 'paused-in-some-future-version',
              'uploads_used': 0,
              'max_uploads': 1,
              'max_bytes': 1,
              'expires_at': '2026-11-15T09:00:00Z',
              'revoked_at': null,
              'created_at': '2026-10-16T09:00:00Z',
            },
          ],
        },
      );
      final rows = await api.list();
      expect(rows.single.state, DropState.unknown);
      expect(rows.single.isOpen, isFalse);
    });

    test('an empty list is empty, not an error', () async {
      when(() => client.get(any(), authed: true))
          .thenAnswer((_) async => <String, dynamic>{'items': <dynamic>[]});
      expect(await api.list(), isEmpty);
    });
  });

  group('DropsApi.arrivals', () {
    test('decodes arrivals and carries every expiry', () async {
      when(() => client.get(any(), authed: true)).thenAnswer(
        (_) async => <String, dynamic>{
          'drop_id': 'd-1',
          'label': 'Smith matter',
          'uploads_used': 2,
          'max_uploads': 5,
          'state': 'open',
          'items': [
            {
              'transfer_id': 't-1',
              'enc_header': 'aGVsbG8=',
              'wrapped_key': 'd3JhcHBlZA==',
              'crypto_suite': 1,
              'byte_count': 2048,
              'status': 'uploaded',
              'created_at': '2026-10-16T09:00:00Z',
              'expires_at': '2026-10-23T09:00:00Z',
            },
            {
              'transfer_id': 't-2',
              'enc_header': 'aGVsbG8=',
              'wrapped_key': null,
              'crypto_suite': 1,
              'byte_count': 1024,
              'status': 'delivered',
              'created_at': '2026-10-15T09:00:00Z',
              'expires_at': '2026-10-22T09:00:00Z',
            },
          ],
        },
      );

      final out = await api.arrivals('d-1');
      expect(out.label, 'Smith matter');
      expect(out.uploadsUsed, 2);
      expect(out.maxUploads, 5);
      expect(out.state, DropState.open);
      expect(out.items, hasLength(2));

      // A drop is a capability, not a container: every item has to
      // carry its own expiry or the view starts implying storage.
      expect(out.items.every((a) => a.expiresAt.isAfter(a.createdAt)), isTrue);

      // Only an uncollected item can be opened.
      expect(out.items.first.collectable, isTrue);
      expect(out.items.last.collectable, isFalse);

      // The sealed key travels with the row so the client can show the
      // real filename without spending the single download.
      expect(out.items.first.wrappedKeyB64, 'd3JhcHBlZA==');
      // Null is valid — link mode has no wrapped key — and must not
      // throw.
      expect(out.items.last.wrappedKeyB64, isNull);

      final path =
          verify(() => client.get(captureAny(), authed: true)).captured.single
              as String;
      expect(path, '/v1/drops/d-1/uploads');
    });

    test('an empty link reports no arrivals, not an error', () async {
      when(() => client.get(any(), authed: true)).thenAnswer(
        (_) async => <String, dynamic>{
          'drop_id': 'd-1',
          'label': 'x',
          'uploads_used': 1,
          'max_uploads': 3,
          'state': 'open',
          'items': <dynamic>[],
        },
      );
      final out = await api.arrivals('d-1');
      expect(out.items, isEmpty);
      // The slot was still spent — an upload was started and abandoned.
      // Both facts are reported; the screen must not conflate them.
      expect(out.uploadsUsed, 1);
    });
  });

  group('DropsApi.revoke', () {
    test('DELETEs the drop and returns the revocation time', () async {
      when(() => client.delete(any(), authed: true)).thenAnswer(
        (_) async => <String, dynamic>{
          'drop_id': 'd-1',
          'revoked_at': '2026-10-16T10:00:00Z',
          'uploads_used': 2,
        },
      );
      final at = await api.revoke('d-1');
      expect(at.toUtc().hour, 10);
      final path = verify(() => client.delete(captureAny(), authed: true))
          .captured
          .single as String;
      expect(path, '/v1/drops/d-1');
    });
  });
}
