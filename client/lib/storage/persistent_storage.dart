// Conditional-import entry point for browser storage persistence.
//
// Web builds resolve to `persistent_storage_web.dart`, which asks the
// browser to exempt this origin from storage eviction. Non-web builds
// resolve to the stub — hardware-backed native storage has no
// equivalent problem.
export 'persistent_storage_stub.dart'
    if (dart.library.js_interop) 'persistent_storage_web.dart';
