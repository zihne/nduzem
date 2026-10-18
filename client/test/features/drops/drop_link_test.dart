import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nduzem/core/config.dart';
import 'package:nduzem/features/drops/drop_link.dart';

final _api = Uri.parse('https://api.nduzem.com');
final _marketing = Uri.parse('https://nduzem.com');
final _app = Uri.parse('https://app.nduzem.com');

void main() {
  const pub = 'jud4aI0FPjlg4ehcRMdjQLQwQwsf2YrCVSLSIFoSHFA=';

  test('route and key both live inside the fragment', () {
    final url = buildDropUploadUrl(
      appUrlBase: Uri.parse('https://nduzem.com'),
      dropId: 'abc-123',
      identityPubB64: pub,
    );
    final parsed = Uri.parse(url);

    // The HTTP request is for the origin only. Everything the client
    // needs is after the '#', which go_router reads as the route
    // (default hash strategy — the app sets no path URL strategy).
    // '/' — the server sees `GET /` and learns nothing else.
    expect(parsed.path, '/');
    expect(parsed.query, isEmpty);
    expect(parsed.fragment, '/drop/abc-123?k=${pub.replaceAll('=', '')}');

    // The whole point: the key must not appear anywhere the browser
    // would transmit. A regression here silently breaks the security
    // property while the link still works.
    final beforeFragment = url.split('#').first;
    expect(beforeFragment, isNot(contains('jud4')));
    expect(beforeFragment, 'https://nduzem.com/');
  });

  test('base64url-encodes without padding, matching link mode', () {
    final url = buildDropUploadUrl(
      appUrlBase: Uri.parse('https://nduzem.com'),
      dropId: 'd',
      identityPubB64: 'ab+cd/ef==',
    );
    expect(url.split('?k=').last, 'ab-cd_ef');
  });

  test('normalises a base with or without a trailing slash', () {
    for (final base in ['https://nduzem.com', 'https://nduzem.com/']) {
      final url = buildDropUploadUrl(
        appUrlBase: Uri.parse(base),
        dropId: 'x',
        identityPubB64: pub,
      );
      expect(Uri.parse(url).fragment, startsWith('/drop/x?k='), reason: base);
      expect(url, isNot(contains('//#')));
    }
  });

  test('refuses to build a link with no owner key', () {
    // Producing `#k=` would look like a working link and would be
    // unusable — fail where the mistake is, not at the uploader.
    expect(
      () => buildDropUploadUrl(
        appUrlBase: Uri.parse('https://nduzem.com'),
        dropId: 'x',
        identityPubB64: '',
      ),
      throwsArgumentError,
    );
    expect(
      () => buildDropUploadUrl(
        appUrlBase: Uri.parse('https://nduzem.com'),
        dropId: '',
        identityPubB64: pub,
      ),
      throwsArgumentError,
    );
  });

  group('the origin a drop link points at', () {
    test('uses the app origin, not the marketing host', () {
      // The bug this exists for: drop links were built from
      // AppConfig.shareUrlBase, which is the bare marketing domain by
      // design. In production that produced
      // https://nduzem.com/#/drop/... which resolves to the marketing
      // site and does nothing. It survived local testing because in
      // development the web app and the share host are the same origin.
      final config = AppConfig(
        apiBaseUrl: _api,
        shareUrlBase: _marketing,
        appUrlBase: _app,
      );
      final url = buildDropUploadUrl(
        appUrlBase: config.appUrlBase,
        dropId: 'd-1',
        identityPubB64: pub,
      );
      expect(url, startsWith('https://app.nduzem.com/#/drop/d-1'));
      expect(url, isNot(contains('//nduzem.com')));
    });

    test('falls back to the share host when no app origin is given', () {
      // Keeps every existing AppConfig construction working, and keeps
      // local development (one host for everything) unchanged.
      final config = AppConfig(apiBaseUrl: _api, shareUrlBase: _marketing);
      expect(config.appUrlBase, _marketing);
    });
  });

  group('decodeOwnerKeyParam', () {
    test('round-trips with the builder', () {
      // The property that matters: whatever the owner's client puts in
      // a link, the uploader's page recovers byte for byte. A parser
      // that disagrees with the builder encrypts to the wrong key.
      final url = buildDropUploadUrl(
        appUrlBase: Uri.parse('https://nduzem.com'),
        dropId: 'd-1',
        identityPubB64: pub,
      );
      // Parse the in-fragment route the way go_router does, then take
      // its `k` parameter — exactly the path the router follows.
      final route = Uri.parse(Uri.parse(url).fragment);
      final recovered = decodeOwnerKeyParam(route.queryParameters['k']);
      expect(recovered, isNotNull);
      expect(recovered, equals(base64Decode(pub)));
    });

    test('handles base64url without padding', () {
      final recovered = decodeOwnerKeyParam('ab-cd_ef');
      expect(recovered, equals(base64Decode('ab+cd/ef')));
    });

    test('adds padding when the length needs it', () {
      // 32 bytes base64-encodes to 44 chars with one '=' of padding,
      // which the builder strips. This is the real shape of a key.
      final key = base64Encode(List<int>.filled(32, 9));
      final stripped = key.replaceAll('+', '-').replaceAll('/', '_')
          .replaceAll('=', '');
      expect(stripped.length % 4, isNot(0), reason: 'needs padding back');
      expect(decodeOwnerKeyParam(stripped), hasLength(32));
    });

    test('decodes a value taken from the route query', () {
      final recovered = decodeOwnerKeyParam('ab-cd_ef');
      expect(recovered, equals(base64Decode('ab+cd/ef')));
    });

    test('returns null for a stripped or malformed fragment', () {
      // Mail clients and chat apps do strip fragments, and a retyped
      // link loses everything after the `#`. Null makes the page say
      // the link is incomplete; a guess would encrypt a document to
      // nothing and report success.
      for (final bad in <String?>[
        null,
        '',
        '!!!not base64!!!',
      ]) {
        expect(decodeOwnerKeyParam(bad), isNull, reason: '$bad');
      }
    });
  });
}
