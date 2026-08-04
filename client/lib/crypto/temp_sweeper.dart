/// Delete decrypted-plaintext leftovers from a previous run.
///
/// The receive screens delete the plaintext temp file in `dispose()`,
/// and the ciphertext temp is dropped in a `finally`. Neither runs when
/// the process is *killed* — a crash, a force-stop, or Android's
/// low-memory killer — so a fully decrypted file can outlive the app in
/// the cache directory. The OS clears app caches only under storage
/// pressure, which can be days.
///
/// For a product whose premise is not leaving plaintext lying around,
/// "until the OS feels like it" is the wrong bound. This makes it "until
/// the next launch", which is the soonest we can act after a kill.
///
/// Deliberately narrow: it only removes files matching the exact naming
/// scheme this app writes, and only ones old enough that they cannot
/// belong to an in-flight receive on this run.
library;

import 'dart:io';

/// Filename shape written by the receive pipeline:
/// `opaqueshare-<slug>.dec.tmp` (plaintext) and `.ct.tmp` (ciphertext).
final RegExp _ourTempFile = RegExp(r'^opaqueshare-[a-z0-9]+\.(dec|ct)\.tmp$');

/// Files younger than this are left alone. A receive in progress on this
/// run owns its temp file, and deleting it mid-stream would break the
/// transfer. Nothing legitimately keeps a temp older than this while
/// still using it: the receive path deletes the ciphertext temp as soon
/// as decryption finishes, and the plaintext temp lives only until the
/// user saves or leaves the screen.
const Duration staleAfter = Duration(hours: 1);

/// Remove stale temps under `tempDir`. Returns how many were deleted.
///
/// Best-effort by design — this runs at startup and must never prevent
/// the app from opening. A file that vanishes between listing and
/// deleting (another isolate, the OS) is a success, not an error.
Future<int> sweepStaleTemps(
  Directory tempDir, {
  DateTime? now,
  Duration olderThan = staleAfter,
}) async {
  if (!await tempDir.exists()) return 0;
  final cutoff = (now ?? DateTime.now()).subtract(olderThan);
  var deleted = 0;
  try {
    await for (final entity in tempDir.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (!_ourTempFile.hasMatch(name)) continue;
      try {
        if ((await entity.lastModified()).isAfter(cutoff)) continue;
        await entity.delete();
        deleted++;
      } on Object {
        // Locked, already gone, permission — skip it. The next launch
        // tries again.
      }
    }
  } on Object {
    // Listing itself failed. Nothing to do but let the app start.
  }
  return deleted;
}
