import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'transfer_history_entry.dart';

/// Local JSON-file persistence for [TransferHistoryEntry] (ADR-0007,
/// ADR-0012) — the **mobile** implementation.
///
/// Loaded via the conditional-import entry point
/// `transfer_history_repository.dart`; on web the browser-local-storage
/// variant (`transfer_history_repository_web.dart`) is used instead.
///
/// One file per signed-in user,
/// `<app-docs>/transfer_history.<userId>.json`, holds that user's
/// list. Every mutation rewrites the file atomically (write to `.tmp`,
/// rename over the target) so a mid-write process death can't leave a
/// corrupted history.
///
/// A 200-entry rolling cap keeps the file well under any parse-hot-
/// path concern (~100 KB max).
///
/// **Scoping (ADR-0012).** The constructor takes a nullable `userId`.
/// When null (no session), reads return empty and mutations no-op —
/// the history screen is only reachable when signed in anyway, so
/// this state shouldn't happen in practice; the null-safety keeps
/// call sites free of ceremony.
///
/// **Legacy migration.** Builds prior to ADR-0012 wrote to an
/// unscoped `<app-docs>/transfer_history.json`. On first use with a
/// non-null `userId`, if the scoped file doesn't exist but the legacy
/// file does, the legacy file is renamed to the scoped path — the
/// currently-signed-in user inherits the history that was accumulated
/// under the single-slot storage model. Idempotent.
///
/// **Web.** `path_provider` doesn't implement
/// `getApplicationDocumentsDirectory` in the browser, so the whole
/// filesystem-based storage layer is a no-op on web: `readAll()`
/// returns `[]`, `log()` / `remove()` / `clearAll()` return early
/// without error. The History screen renders empty on web. Proper
/// browser-side persistence (localStorage / IndexedDB) is a follow-up.
class TransferHistoryRepository {
  TransferHistoryRepository({
    this.userId,
    Directory? directoryOverride,
  }) : _directoryOverride = directoryOverride;

  /// Local user id whose history this repo scopes to. Null when no
  /// session is active; all methods no-op in that case.
  final String? userId;

  /// Test seam. When provided, the repository writes into this
  /// directory instead of `getApplicationDocumentsDirectory()`.
  final Directory? _directoryOverride;

  static const int maxEntries = 200;
  static const int _schemaVersion = 1;
  static const String _legacyFileName = 'transfer_history.json';

  static String _fileNameFor(String userId) => 'transfer_history.$userId.json';

  Future<Directory> _dir() async =>
      _directoryOverride ?? await getApplicationDocumentsDirectory();

  Future<File?> _file() async {
    final uid = userId;
    if (uid == null) return null;
    return File('${(await _dir()).path}/${_fileNameFor(uid)}');
  }

  /// One-time rename of the pre-ADR-0012 unscoped file into the
  /// current user's scoped slot. Attributes the legacy history to
  /// the signed-in user — under the single-slot storage model those
  /// were their entries in practice. Runs implicitly at every op
  /// (cheap `File.exists()` probe) so a bare `readAll()` from a
  /// fresh screen mount is enough to trigger it.
  Future<void> _migrateIfNeeded() async {
    final uid = userId;
    if (uid == null) return;
    final dir = await _dir();
    final scoped = File('${dir.path}/${_fileNameFor(uid)}');
    if (await scoped.exists()) return;
    final legacy = File('${dir.path}/$_legacyFileName');
    if (!await legacy.exists()) return;
    await legacy.rename(scoped.path);
  }

  /// Read the persisted list. Returns an empty list if the file
  /// doesn't exist, the schema version doesn't match this build, or
  /// there's no active session.
  Future<List<TransferHistoryEntry>> readAll() async {
    await _migrateIfNeeded();
    final f = await _file();
    if (f == null) return const [];
    if (!await f.exists()) return const [];
    final raw = await f.readAsString();
    if (raw.trim().isEmpty) return const [];
    final Map<String, dynamic> outer;
    try {
      outer = jsonDecode(raw) as Map<String, dynamic>;
    } on FormatException {
      // Corrupt file — safer to discard than to explode.
      return const [];
    }
    final version = (outer['schema_version'] as num?)?.toInt() ?? 0;
    if (version != _schemaVersion) return const [];
    final entries = (outer['entries'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>()
        .map(TransferHistoryEntry.fromJson)
        .whereType<TransferHistoryEntry>()
        .toList(growable: false);
    return entries;
  }

  /// Prepend a new entry; trim to [maxEntries] if we've grown past it.
  /// No-op when no session is active.
  Future<List<TransferHistoryEntry>> log(TransferHistoryEntry entry) async {
    if (userId == null) return const [];
    final current = await readAll();
    final next = [entry, ...current];
    if (next.length > maxEntries) {
      next.removeRange(maxEntries, next.length);
    }
    await _writeAll(next);
    return next;
  }

  /// Remove one entry by `transferId`. No-op when the id isn't
  /// present or no session is active.
  Future<List<TransferHistoryEntry>> remove(String transferId) async {
    if (userId == null) return const [];
    final current = await readAll();
    final next = current.where((e) => e.transferId != transferId).toList();
    if (next.length == current.length) return current;
    await _writeAll(next);
    return next;
  }

  /// Drop everything for the current user. Leaves the file at `[]`
  /// rather than deleting it — subsequent reads still work without
  /// touching the FS. No-op when no session is active.
  Future<void> clearAll() async {
    if (userId == null) return;
    await _writeAll(const []);
  }

  Future<void> _writeAll(List<TransferHistoryEntry> entries) async {
    final target = await _file();
    if (target == null) return;
    final payload = jsonEncode({
      'schema_version': _schemaVersion,
      'entries': entries.map((e) => e.toJson()).toList(growable: false),
    });
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(payload, flush: true);
    // Rename is atomic on the same filesystem — success replaces the
    // previous file's contents in one step, no half-written state
    // ever observable by concurrent readers.
    await tmp.rename(target.path);
  }
}
