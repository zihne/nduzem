// Conditional-import entry point for [BlobPlaintextSource] (ADR-0013 Phase 4).
//
// Web builds resolve to `blob_plaintext_source_web.dart` which
// depends on `package:web`. Non-web builds (VM tests, mobile) resolve
// to `blob_plaintext_source_stub.dart` which throws at construction —
// mobile has [FilePlaintextSource] and never touches this class.
export 'blob_plaintext_source_stub.dart'
    if (dart.library.js_interop) 'blob_plaintext_source_web.dart';
