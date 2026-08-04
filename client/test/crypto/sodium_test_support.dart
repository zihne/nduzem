import 'dart:ffi';
import 'dart:io';

import 'package:sodium/sodium.ffi.dart' as sodium_ffi;
import 'package:sodium_libs/sodium_libs.dart';

/// Getting a real libsodium into `flutter test`.
///
/// `SodiumInit.init()` from `sodium_libs` resolves the native library
/// through the Flutter plugin, which needs a real platform. Under
/// `flutter test` — a plain Dart VM — it throws
/// `LateInitializationError: Field '_instance' has not been
/// initialized`.
///
/// That failure used to be swallowed into a `skipReason` string, and
/// every crypto test began `if (skipReason != null) return;`. The
/// result was 22 tests reporting **passed** while executing not one
/// assertion — verified by inverting every assertion in the integrity
/// suite and watching it stay green. The crypto core, which the
/// product's entire security claim rests on, had no automated
/// verification at all.
///
/// So: try the plugin first (works in `integration_test` on a device),
/// then fall back to loading the system libsodium over FFI, which works
/// in a host VM test. The crypto under test is platform-independent —
/// the same libsodium primitives either way — so host-side coverage is
/// real coverage, not a simulation.
///
/// If neither works this returns null and callers must pass it to
/// `skip:` so the runner prints SKIPPED. Never let absence of libsodium
/// read as a pass.
Future<Sodium?> tryInitSodium() async {
  try {
    return await SodiumInit.init();
  } on Object {
    // Expected under `flutter test`; fall through to FFI.
  }

  for (final candidate in _libraryCandidates()) {
    try {
      return await sodium_ffi.SodiumInit.init(
        () => DynamicLibrary.open(candidate),
      );
    } on Object {
      // Try the next path.
    }
  }
  return null;
}

/// Reason string for `skip:`, or null when libsodium loaded. Phrased so
/// a skipped run tells the reader how to turn it into a real one.
///
/// Throws instead of skipping when `REQUIRE_LIBSODIUM` is set, which CI
/// does. A skipped test is green, and "green because the crypto tests
/// silently did not run" is the exact failure this whole harness exists
/// to prevent — moving it from a developer laptop into CI would be no
/// improvement. Locally the flag is unset, so a missing libsodium is a
/// visible skip rather than a blocked commit.
String? sodiumSkipReason(Sodium? sodium) {
  if (sodium != null) return null;
  const advice =
      'libsodium not loadable on this host — crypto assertions did NOT run. '
      'Install it (macOS: `brew install libsodium`, Debian: '
      '`apt-get install -y libsodium23`), set LIBSODIUM_PATH to a specific '
      'build, or run these under `flutter test integration_test/` on a '
      'device.';
  if (Platform.environment['REQUIRE_LIBSODIUM'] == '1') {
    throw StateError('REQUIRE_LIBSODIUM=1 but $advice');
  }
  return advice;
}

Iterable<String> _libraryCandidates() sync* {
  // An explicit LIBSODIUM_PATH is the ONLY candidate, never merely the
  // first. Falling back to a discovered library after an explicit pin
  // failed would run the tests against something other than the build
  // that was asked for, and report success — the pin would be silently
  // meaningless rather than loudly wrong.
  final override = Platform.environment['LIBSODIUM_PATH'];
  if (override != null && override.isNotEmpty) {
    yield override;
    return;
  }

  if (Platform.isMacOS) {
    yield '/opt/homebrew/lib/libsodium.dylib'; // Apple silicon
    yield '/usr/local/lib/libsodium.dylib'; // Intel
    yield 'libsodium.dylib'; // whatever the loader finds
  } else if (Platform.isLinux) {
    yield 'libsodium.so.23';
    yield 'libsodium.so';
    yield '/usr/lib/x86_64-linux-gnu/libsodium.so.23';
  } else if (Platform.isWindows) {
    yield 'libsodium.dll';
  }
}
