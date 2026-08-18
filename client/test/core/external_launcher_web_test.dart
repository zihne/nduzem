// The Terms and Privacy links on the registration screen were dead on the
// web app, and silently so.
//
// `external_launcher.dart` imports `dart:io` and branched on
// `Platform.isAndroid`. On web `dart:io` is STUBBED, not rejected — the
// import compiles and `flutter build web` succeeds — but reading
// `Platform.isAndroid` throws `UnsupportedError` at runtime. So
// `launchExternalUri` died before url_launcher was ever reached, the
// throw surfaced as an unhandled async error inside a TapGestureRecognizer,
// and the user saw a link that did nothing at all.
//
// Nothing catches this without a browser: it compiles, it analyses clean,
// and every non-web platform works. Hence a test pinned to `browser`.
@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:nduzem/core/external_launcher.dart';

void main() {
  test('launchExternalUri never touches dart:io Platform on web', () async {
    // Any UnsupportedError here means the `dart:io` branch was evaluated
    // — the exact regression. url_launcher itself may well fail in a
    // headless test browser (no plugin registration, no popup allowed);
    // that is a different failure and not what this guards.
    try {
      await launchExternalUri(Uri.parse('https://nduzem.com/terms.html'));
    } on UnsupportedError catch (e) {
      fail(
        'launchExternalUri evaluated dart:io Platform on web ($e). '
        'The kIsWeb guard has been removed or short-circuited, and the '
        'legal links on the registration screen are dead again.',
      );
    } catch (_) {
      // url_launcher declining to open in a headless browser is fine.
    }
  });
}
