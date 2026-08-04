import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'crypto/temp_sweeper.dart';

/// OpaqueShare Flutter client.
///
/// Crypto is client-side (libsodium via `sodium_libs`). Private keys never
/// leave the device (`flutter_secure_storage`). Open-source under Apache-2.0
/// (spec §14) to enable verifiable builds + audit.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Clear decrypted-plaintext leftovers from a previous run. The receive
  // screens delete their temp in `dispose()`, which does NOT run when the
  // process is killed — a crash, a force-stop, or the low-memory killer —
  // so a fully decrypted file can otherwise sit in the cache until the OS
  // reclaims it, which can be days.
  //
  // Deliberately NOT awaited: it must never delay the app opening, and it
  // has nothing the first frame depends on. Web has no such temps (the
  // browser receive path assembles plaintext in memory), so it is skipped
  // there rather than reaching for a filesystem that isn't present.
  if (!kIsWeb) {
    unawaited(
      getTemporaryDirectory()
          .then(sweepStaleTemps)
          // Startup must survive a sweep failure: a locked file or an
          // unreadable cache directory is not a reason to fail to launch.
          .catchError((Object _) => 0),
    );
  }
  runApp(const ProviderScope(child: OpaqueShareApp()));
}
