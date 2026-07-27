// Conditional-import entry point for the browser save utility
// (ADR-0013 Phase 6).
//
// Web builds resolve to `web_saver_web.dart` which depends on
// `package:web` — File System Access API with an `<a download>`
// fallback for browsers that don't support FSA (Firefox, Safari).
// Non-web builds resolve to the stub — mobile has SAF and never
// touches this file.
export 'web_saver_stub.dart'
    if (dart.library.js_interop) 'web_saver_web.dart';
