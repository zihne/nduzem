import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'transfer_history_entry.dart';

/// Local JSON-file persistence for [TransferHistoryEntry] (ADR-0007).
///
/// One file, `<app-docs>/transfer_history.json`, holds the full list.
/// Every mutation rewrites the file atomically (write to `.tmp`,
/// rename over the target) so a mid-write process death can't leave
/// a corrupted history.
///
/// A 200-entry rolling cap keeps the file well under any parse-hot-
/// path concern (~100 KB max).
class TransferHistoryRepository {
  TransferHistoryRepository({Directory? directoryOverride})
      : _directoryOverride = directoryOverride;

  /// Test seam. When provided, the repository writes into this
  /// directory instead of `getApplicationDocumentsDirectory()`.
  final Directory? _directoryOverride;

  static const int maxEntries = 200;
  static const int _schemaVersion = 1;
  static const String _fileName = 'transfer_history.json';

  Future<Directory> _dir() async =>
      _directoryOverride ?? await getApplicationDocumentsDirectory();

  Future<File> _file() async => File('${(await _dir()).path}/$_fileName');

  /// Read the persisted list. Returns an empty list if the file
  /// doesn't exist or the schema version doesn't match this build
  /// (a future migration would branch on `schemaVersion` here).
  Future<List<TransferHistoryEntry>> readAll() async {
    final f = await _file();
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
  Future<List<TransferHistoryEntry>> log(TransferHistoryEntry entry) async {
    final current = await readAll();
    final next = [entry, ...current];
    if (next.length > maxEntries) {
      next.removeRange(maxEntries, next.length);
    }
    await _writeAll(next);
    return next;
  }

  /// Remove one entry by `transferId`. No-op when the id isn't
  /// present.
  Future<List<TransferHistoryEntry>> remove(String transferId) async {
    final current = await readAll();
    final next = current.where((e) => e.transferId != transferId).toList();
    if (next.length == current.length) return current;
    await _writeAll(next);
    return next;
  }

  /// Drop everything. Leaves the file at `[]` rather than deleting
  /// it — subsequent reads still work without touching the FS.
  Future<void> clearAll() async {
    await _writeAll(const []);
  }

  Future<void> _writeAll(List<TransferHistoryEntry> entries) async {
    final payload = jsonEncode({
      'schema_version': _schemaVersion,
      'entries': entries.map((e) => e.toJson()).toList(growable: false),
    });
    final target = await _file();
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(payload, flush: true);
    // Rename is atomic on the same filesystem — success replaces the
    // previous file's contents in one step, no half-written state
    // ever observable by concurrent readers.
    await tmp.rename(target.path);
  }
}
