import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'transfer_history_entry.dart';
import 'transfer_history_repository.dart';

/// Repository seam — override in tests to point at a tmp dir.
final transferHistoryRepositoryProvider =
    Provider<TransferHistoryRepository>((_) => TransferHistoryRepository());

/// Newest-first list of the local user's transfer history.
///
/// `build` reads the file once; every mutation writes through the
/// repository and re-emits the fresh list. The screen watches this;
/// send/receive screens call [TransferHistoryNotifier.log] after a
/// successful transfer (ADR-0007).
final transferHistoryProvider = AsyncNotifierProvider<TransferHistoryNotifier,
    List<TransferHistoryEntry>>(TransferHistoryNotifier.new);

class TransferHistoryNotifier
    extends AsyncNotifier<List<TransferHistoryEntry>> {
  @override
  Future<List<TransferHistoryEntry>> build() async {
    final repo = ref.watch(transferHistoryRepositoryProvider);
    return repo.readAll();
  }

  Future<void> log(TransferHistoryEntry entry) async {
    final repo = ref.read(transferHistoryRepositoryProvider);
    final next = await repo.log(entry);
    state = AsyncData(next);
  }

  Future<void> remove(String transferId) async {
    final repo = ref.read(transferHistoryRepositoryProvider);
    final next = await repo.remove(transferId);
    state = AsyncData(next);
  }

  Future<void> clearAll() async {
    final repo = ref.read(transferHistoryRepositoryProvider);
    await repo.clearAll();
    state = const AsyncData(<TransferHistoryEntry>[]);
  }
}
