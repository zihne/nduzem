import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nduzem/features/drops/drop_link.dart';

void main() {
  const pub = 'jud4aI0FPjlg4ehcRMdjQLQwQwsf2YrCVSLSIFoSHFA=';

  test('key rides in the fragment, never the path or query', () {
    final url = buildDropUploadUrl(
      shareUrlBase: Uri.parse('https://nduzem.com'),
      dropId: 'abc-123',
      identityPubB64: pub,
    );
    final parsed = Uri.parse(url);

    expect(parsed.path, '/drop/abc-123');
    expect(parsed.query, isEmpty);
    expect(parsed.fragment, startsWith('k='));

    // The whole point: the key must not appear anywhere the browser
    // would transmit. A regression here silently breaks the security
    // property while the link still works.
    final beforeFragment = url.split('#').first;
    expect(beforeFragment, isNot(contains('jud4')));
  });

  test('base64url-encodes without padding, matching link mode', () {
    final url = buildDropUploadUrl(
      shareUrlBase: Uri.parse('https://nduzem.com'),
      dropId: 'd',
      identityPubB64: 'ab+cd/ef==',
    );
    expect(url.split('#k=').last, 'ab-cd_ef');
  });

  test('normalises a base with or without a trailing slash', () {
    for (final base in ['https://nduzem.com', 'https://nduzem.com/']) {
      final url = buildDropUploadUrl(
        shareUrlBase: Uri.parse(base),
        dropId: 'x',
        identityPubB64: pub,
      );
      expect(Uri.parse(url).path, '/drop/x', reason: base);
      expect(url, isNot(contains('//drop')));
    }
  });

  test('refuses to build a link with no owner key', () {
    // Producing `#k=` would look like a working link and would be
    // unusable — fail where the mistake is, not at the uploader.
    expect(
      () => buildDropUploadUrl(
        shareUrlBase: Uri.parse('https://nduzem.com'),
        dropId: 'x',
        identityPubB64: '',
      ),
      throwsArgumentError,
    );
    expect(
      () => buildDropUploadUrl(
        shareUrlBase: Uri.parse('https://nduzem.com'),
        dropId: '',
        identityPubB64: pub,
      ),
      throwsArgumentError,
    );
  });

  group('parseDropFragmentKey', () {
    test('round-trips with the builder', () {
      // The property that matters: whatever the owner's client puts in
      // a link, the uploader's page recovers byte for byte. A parser
      // that disagrees with the builder encrypts to the wrong key.
      final url = buildDropUploadUrl(
        shareUrlBase: Uri.parse('https://nduzem.com'),
        dropId: 'd-1',
        identityPubB64: pub,
      );
      final recovered = parseDropFragmentKey(Uri.parse(url).fragment);
      expect(recovered, isNotNull);
      expect(recovered, equals(base64Decode(pub)));
    });

    test('handles base64url without padding', () {
      final recovered = parseDropFragmentKey('k=ab-cd_ef');
      expect(recovered, equals(base64Decode('ab+cd/ef')));
    });

    test('adds padding when the length needs it', () {
      // 32 bytes base64-encodes to 44 chars with one '=' of padding,
      // which the builder strips. This is the real shape of a key.
      final key = base64Encode(List<int>.filled(32, 9));
      final stripped = key.replaceAll('+', '-').replaceAll('/', '_')
          .replaceAll('=', '');
      expect(stripped.length % 4, isNot(0), reason: 'needs padding back');
      expect(parseDropFragmentKey('k=$stripped'), hasLength(32));
    });

    test('tolerates other fragment params around it', () {
      final recovered = parseDropFragmentKey('x=1&k=ab-cd_ef&y=2');
      expect(recovered, equals(base64Decode('ab+cd/ef')));
    });

    test('returns null for a stripped or malformed fragment', () {
      // Mail clients and chat apps do strip fragments, and a retyped
      // link loses everything after the `#`. Null makes the page say
      // the link is incomplete; a guess would encrypt a document to
      // nothing and report success.
      for (final bad in <String>[
        '',
        'k=',
        'nothing-here',
        'kk=abcd',
        'k=!!!not base64!!!',
      ]) {
        expect(parseDropFragmentKey(bad), isNull, reason: bad);
      }
    });
  });
}
