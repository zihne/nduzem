// Conditional-import entry point for the browser-native file picker
// used by [SendScreen] on web (ADR-0013 Phase 4).
//
// The web implementation depends on `package:web`; that package
// doesn't compile on the Dart VM (fails inside package-internal
// helpers). So we split the code the same way as
// `blob_plaintext_source.dart`: web builds resolve to
// `web_file_picker_web.dart`; VM / mobile builds resolve to the
// stub, which throws if called.
export 'web_file_picker_stub.dart'
    if (dart.library.js_interop) 'web_file_picker_web.dart';
