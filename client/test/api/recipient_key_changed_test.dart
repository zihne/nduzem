// ADR-0039: a 409 `recipient_key_changed` must arrive as a TYPE.
//
// The send screen has to branch on it — drop the cached recipient, re-run
// the full lookup, and warn if the contact was previously verified. If
// the client instead matched on the message text, a reworded or
// translated server message would fall through to the GENERIC error
// path, and the user would see "something went wrong" instead of a
// key-change warning. That failure is silent and lands precisely where
// this design is meant to help.
//
// So: assert the type, and assert it survives alongside the other 409s
// that must NOT be mistaken for it.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:nduzem/api/api_client.dart';
import 'package:nduzem/core/config.dart';

class _NoToken implements TokenSource {
  @override
  Future<String?> readAccessToken() async => 'token';
  @override
  Future<String?> refreshAccessToken() async => null;
}

ApiClient _clientReturning(int status, Object body) => ApiClient(
      config: AppConfig(
        apiBaseUrl: Uri.parse('http://test/'),
        shareUrlBase: Uri.parse('http://test/'),
      ),
      tokenSource: _NoToken(),
      httpClient: MockClient(
        (_) async => http.Response(
          jsonEncode(body),
          status,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );

void main() {
  test('a structured 409 becomes RecipientKeyChangedException', () async {
    final client = _clientReturning(409, {
      'detail': {
        'error': 'recipient_key_changed',
        'message': "The recipient's encryption key has changed.",
      },
    });

    await expectLater(
      client.post('/v1/transfers/initiate', body: const {}, authed: true),
      throwsA(isA<RecipientKeyChangedException>()),
    );
  });

  test('the server message is carried through, not replaced', () async {
    final client = _clientReturning(409, {
      'detail': {
        'error': 'recipient_key_changed',
        'message': 'Bespoke server wording.',
      },
    });

    try {
      await client.post('/v1/transfers/initiate', body: const {}, authed: true);
      fail('expected a throw');
    } on RecipientKeyChangedException catch (exc) {
      expect(exc.message, 'Bespoke server wording.');
      expect(exc.statusCode, 409);
    }
  });

  test('an unrelated 409 stays a plain ApiException', () async {
    // `/initiate` also returns 409 when the recipient has not verified
    // their email. Treating that as a key change would clear the cache
    // and re-look-up for no reason, and would tell the user something
    // false about their contact's keys.
    final client = _clientReturning(409, {
      'detail': 'Recipient has not verified their email yet.',
    });

    try {
      await client.post('/v1/transfers/initiate', body: const {}, authed: true);
      fail('expected a throw');
    } on RecipientKeyChangedException {
      fail('an unrelated 409 must not be typed as a key change');
    } on ApiException catch (exc) {
      expect(exc.statusCode, 409);
      expect(exc.message, contains('verified their email'));
    }
  });

  test('a 409 with a different structured code is not a key change',
      () async {
    final client = _clientReturning(409, {
      'detail': {'error': 'something_else'},
    });

    try {
      await client.post('/v1/transfers/initiate', body: const {}, authed: true);
      fail('expected a throw');
    } on RecipientKeyChangedException {
      fail('only recipient_key_changed may produce this type');
    } on ApiException catch (exc) {
      expect(exc.statusCode, 409);
    }
  });
}
