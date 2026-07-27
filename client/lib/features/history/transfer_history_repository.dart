// Conditional-import entry point for [TransferHistoryRepository]
// (ADR-0007, ADR-0012).
//
// Mobile / VM: `_io.dart` — filesystem JSON at `<app-docs>/…`.
// Web: `_web.dart` — `window.localStorage` key/value.
//
// Both files export a class named `TransferHistoryRepository` with
// the same public API, so callers use the shared name here without
// caring which backing store they got.
export 'transfer_history_repository_io.dart'
    if (dart.library.js_interop) 'transfer_history_repository_web.dart';
