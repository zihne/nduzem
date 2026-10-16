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
}
