import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Ask the browser to put this origin's storage in **persistent** mode.
///
/// The identity private key lives in browser storage on web, and browsers
/// treat script-writable storage as disposable by default. WebKit's
/// storage policy deletes *all* of it — localStorage, IndexedDB, service
/// worker registrations — after seven days of Safari use without a user
/// interaction on the site. A file-transfer tool is occasional-use by
/// nature, so "hasn't been opened in a week of browsing" is the ordinary
/// case, not an edge case.
///
/// The consequence is not a lost session. `identity_pub` is published on
/// the server at registration and there is no rotation endpoint, so a
/// user whose storage is evicted can still log in, still sees their
/// account, and can no longer decrypt anything ever sent to them — with
/// no way to publish a replacement key.
///
/// WebKit's eviction algorithm skips origins in persistent mode, so this
/// call is the cheapest defence available. Two things it is NOT:
///
///  - **Not a guarantee.** `persist()` is a *request*. Browsers grant it
///    on engagement heuristics (bookmarked, installed, frequently used),
///    and may refuse. Treat a `false` return as the normal case, not an
///    error.
///  - **Not recovery.** It does nothing if the user clears site data,
///    opens a different browser, or loses the device. Durability of the
///    only copy is not the same as having more than one copy.
///
/// Returns whether the origin now has persistent storage — including
/// when it already did, since `persist()` is idempotent. Never throws:
/// this runs at startup and must not be able to prevent the app opening.
Future<bool> requestPersistentStorage() async {
  try {
    final storage = web.window.navigator.storage;
    // Safari exposed `persisted()` before `persist()` in some versions,
    // and non-secure contexts omit StorageManager entirely, so check
    // rather than assume the method is there.
    if (!storage.isDefinedAndNotNull) return false;
    final already = await storage.persisted().toDart;
    if (already.toDart) return true;
    final granted = await storage.persist().toDart;
    return granted.toDart;
  } on Object {
    // Any failure here — missing API, an insecure context, a browser
    // that throws instead of resolving false — means we simply do not
    // get the exemption. It is never a reason to fail startup.
    return false;
  }
}
