import 'dart:convert';
import 'dart:io' show Directory;

import 'package:web/web.dart' as web;

import 'transfer_history_entry.dart';

/// Browser localStorage persistence for [TransferHistoryEntry] —
/// the **web** implementation.
///
/// Loaded via the conditional-import entry point
/// `transfer_history_repository.dart`. Mobile uses the file-based
/// variant instead. Chose `localStorage` over `IndexedDB` because
/// the payload (200-entry cap × ~500 bytes ≈ 100 KB) sits well
/// inside every browser's localStorage quota (~5 MiB) and the
/// synchronous key/value shape needs a fraction of the code that
/// IndexedDB's transactional/versioned API demands.
///
/// One key per signed-in user, `opaqueshare.history.<userId>`,
/// holds that user's JSON list. Same 200-entry cap + schema
/// versioning as the mobile impl so the History screen renders the
/// same shape on both platforms.
///
/// **Persistence caveats.** localStorage survives page reloads and
/// browser restarts, but the user (or the browser itself) can clear
/// it: private / incognito modes wipe on session end in Safari and
/// Firefox; explicit "Clear site data" removes it everywhere. The
/// server holds the canonical transfer records — history is a
/// local convenience, not a source of truth (ADR-0007).
class TransferHistoryRepository {
  TransferHistoryRepository({
    this.userId,
    // Signature-parity stub with the mobile variant so the shared
    // provider can construct either impl with the same call. Ignored
    // on web — there's no filesystem to override.
    Directory? directoryOverride,
  });

  /// Local user id whose history this repo scopes to. Null when no
  /// session is active; all methods no-op in that case.
  final String? userId;

  static const int maxEntries = 200;
  static const int _schemaVersion = 1;

  static String _storageKeyFor(String userId) =>
      'opaqueshare.history.$userId';

  web.Storage get _store => web.window.localStorage;

  String? _readRaw() {
    final uid = userId;
    if (uid == null) return null;
    return _store.getItem(_storageKeyFor(uid));
  }

  void _writeRaw(String payload) {
    final uid = userId;
    if (uid == null) return;
    _store.setItem(_storageKeyFor(uid), payload);
  }

  /// Read the persisted list. Returns an empty list when there's no
  /// active session, no stored payload, or the schema doesn't match.
  Future<List<TransferHistoryEntry>> readAll() async {
    final raw = _readRaw();
    if (raw == null || raw.trim().isEmpty) return const [];
    final Map<String, dynamic> outer;
    try {
      outer = jsonDecode(raw) as Map<String, dynamic>;
    } on FormatException {
      // Corrupt payload — safer to discard than to explode.
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
    _writeAll(next);
    return next;
  }

  /// Remove one entry by `transferId`. No-op when the id isn't
  /// present or no session is active.
  Future<List<TransferHistoryEntry>> remove(String transferId) async {
    if (userId == null) return const [];
    final current = await readAll();
    final next = current.where((e) => e.transferId != transferId).toList();
    if (next.length == current.length) return current;
    _writeAll(next);
    return next;
  }

  /// Drop everything for the current user. Removes the localStorage
  /// key entirely (mobile leaves the file with `[]` to save a
  /// syscall on the next read; localStorage doesn't have that
  /// distinction).
  Future<void> clearAll() async {
    final uid = userId;
    if (uid == null) return;
    _store.removeItem(_storageKeyFor(uid));
  }

  void _writeAll(List<TransferHistoryEntry> entries) {
    final payload = jsonEncode({
      'schema_version': _schemaVersion,
      'entries': entries.map((e) => e.toJson()).toList(growable: false),
    });
    _writeRaw(payload);
  }
}
