import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:nduzem/api/api_client.dart';
import 'package:nduzem/core/config.dart';

class _NoToken implements TokenSource {
  @override
  Future<String?> readAccessToken() async => null;
  @override
  Future<String?> refreshAccessToken() async => null;
}

ApiClient _client(MockClient mock) => ApiClient(
      config: AppConfig(
        apiBaseUrl: Uri.parse('http://test/'),
        shareUrlBase: Uri.parse('http://test/'),
      ),
      tokenSource: _NoToken(),
      httpClient: mock,
    );

/// Build a client whose next call returns a FastAPI-shaped 422.
ApiClient _clientReturning422(List<Map<String, dynamic>> detail) => _client(
      MockClient(
        (req) async => http.Response(
          jsonEncode({'detail': detail}),
          422,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );

void main() {
  group('422 validation errors are surfaced, not swallowed', () {
    test('names the missing field instead of "HTTP 422"', () async {
      // The regression: `detail` on a 422 is a LIST, and _decode only
      // read it when it was a String, so the server telling us exactly
      // which field it rejected became the useless string "HTTP 422".
      final detail = <Map<String, dynamic>>[
        {
          'type': 'missing',
          'loc': ['body', 'byte_count'],
          'msg': 'Field required',
          'input': {'mode': 'app'},
        },
      ];
      final client = _clientReturning422(detail);

      await expectLater(
        client.post('/v1/transfers/initiate', body: const {}),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 422)
              .having(
                (e) => e.message,
                'message',
                'byte_count: Field required',
              ),
        ),
      );
    });

    test('renders a whole-model validator failure (loc is just [body])',
        () async {
      // InitiateTransferRequest._check_mode_fields raises these — they
      // carry no field path, so the message must stand alone rather than
      // being prefixed with an empty location.
      final detail = <Map<String, dynamic>>[
        {
          'type': 'value_error',
          'loc': ['body'],
          'msg': 'Value error, link_password is link-mode only',
        },
      ];
      final client = _clientReturning422(detail);

      await expectLater(
        client.post('/v1/transfers/initiate', body: const {}),
        throwsA(
          isA<ApiException>().having(
            (e) => e.message,
            'message',
            'Value error, link_password is link-mode only',
          ),
        ),
      );
    });

    test('joins multiple field errors', () async {
      final detail = <Map<String, dynamic>>[
        {
          'type': 'missing',
          'loc': ['body', 'blob_sha256'],
          'msg': 'Field required',
        },
        {
          'type': 'string_too_short',
          'loc': ['body', 'enc_header'],
          'msg': 'String should have at least 1 character',
        },
      ];
      final client = _clientReturning422(detail);

      await expectLater(
        client.post('/v1/transfers/x/commit', body: const {}),
        throwsA(
          isA<ApiException>().having(
            (e) => e.message,
            'message',
            'blob_sha256: Field required; '
                'enc_header: String should have at least 1 character',
          ),
        ),
      );
    });

    test('never leaks the echoed request body', () async {
      // FastAPI echoes the offending input. On this API that can hold an
      // email address, a link password, or an encrypted header — none of
      // which belongs in a SnackBar or a screenshotted bug report.
      final detail = <Map<String, dynamic>>[
        {
          'type': 'value_error',
          'loc': ['body', 'recipient_email'],
          'msg': 'value is not a valid email address',
          'input': {
            'recipient_email': 'secret@example.com',
            'link_password': 'hunter2',
          },
        },
      ];
      final client = _clientReturning422(detail);

      try {
        await client.post('/v1/transfers/initiate', body: const {});
        fail('expected ApiException');
      } on ApiException catch (exc) {
        expect(exc.message, contains('recipient_email'));
        expect(exc.message, isNot(contains('secret@example.com')));
        expect(exc.message, isNot(contains('hunter2')));
      }
    });

    test('nested loc segments are joined with dots', () async {
      final detail = <Map<String, dynamic>>[
        {
          'type': 'missing',
          'loc': ['body', 'parts', 0, 'etag'],
          'msg': 'Field required',
        },
      ];
      final client = _clientReturning422(detail);

      await expectLater(
        client.post('/v1/transfers/x/commit', body: const {}),
        throwsA(
          isA<ApiException>().having(
            (e) => e.message,
            'message',
            'parts.0.etag: Field required',
          ),
        ),
      );
    });

    test('falls back to the status code when detail is unparseable', () async {
      // Guardrail: a non-FastAPI 422 (proxy, WAF) must not crash the
      // formatter or produce an empty message.
      final client = _client(
        MockClient(
          (req) async => http.Response('not json at all', 422),
        ),
      );

      await expectLater(
        client.post('/v1/transfers/initiate', body: const {}),
        throwsA(
          isA<ApiException>().having((e) => e.message, 'message', 'HTTP 422'),
        ),
      );
    });

    test('an empty detail list falls back rather than showing nothing',
        () async {
      final client = _clientReturning422(<Map<String, dynamic>>[]);

      await expectLater(
        client.post('/v1/transfers/initiate', body: const {}),
        throwsA(
          isA<ApiException>().having((e) => e.message, 'message', 'HTTP 422'),
        ),
      );
    });
  });
}
