import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart';
import '../../api/users_api.dart';
import '../auth/auth_providers.dart';
import '../history/transfer_history_entry.dart';
import '../history/transfer_history_provider.dart';
import 'picked_file.dart';
import 'transfer_service.dart';

/// Multi-file app-mode batch send (ADR-0009).
///
/// The controller snapshots one recipient + one list of picked files,
/// runs them serially through [TransferService.send], and updates the
/// shared [SendQueueState] after each event. Failure of one item does
/// not halt the batch — the next item starts. Cancel drops the queue:
/// the in-flight file's [CancelToken] fires and every remaining item
/// transitions to [QueueItemStatus.cancelled].
///
/// A [QuotaExceededException] is treated as batch-wide (the balance
/// isn't going to grow between file N and N+1) so the controller
/// surfaces the specific error, cancels the rest, and lets the
/// completion screen render the "Buy more credit" CTA.
///
/// Each successful item logs its own [SentHistoryEntry] (ADR-0007) —
/// consistent with the single-file path.
enum QueueItemStatus {
  pending,
  encrypting,
  uploading,
  done,
  failed,
  cancelled,
}

class QueuedSend {
  const QueuedSend({
    required this.localId,
    required this.file,
    required this.status,
    this.transferId,
    this.byteCountOnServer,
    this.errorMessage,
    this.phase,
    this.phaseDone,
    this.phaseTotal,
  });

  /// Stable identity for the row in the UI list, independent of
  /// filesystem paths (two picks of the same file get distinct ids).
  final String localId;
  final PickedFile file;
  final QueueItemStatus status;

  /// Server-assigned id after a successful commit. Null in every
  /// non-done state.
  final String? transferId;

  /// Byte count the server accepted at commit. Null in every non-done
  /// state. Passed to the history entry so the row matches the
  /// single-file path.
  final int? byteCountOnServer;

  /// Human-readable error on failure. Uses the friendly `.message` on
  /// [ApiException] subclasses, so the completion grid can render it
  /// verbatim without unwrapping.
  final String? errorMessage;

  /// Current phase within [status] == encrypting/uploading. Null
  /// otherwise. Fed back into the receive screen's existing
  /// single-file progress bar without translation.
  final SendPhase? phase;
  final int? phaseDone;
  final int? phaseTotal;

  QueuedSend copyWith({
    QueueItemStatus? status,
    String? transferId,
    int? byteCountOnServer,
    String? errorMessage,
    SendPhase? phase,
    int? phaseDone,
    int? phaseTotal,
  }) {
    return QueuedSend(
      localId: localId,
      file: file,
      status: status ?? this.status,
      transferId: transferId ?? this.transferId,
      byteCountOnServer: byteCountOnServer ?? this.byteCountOnServer,
      errorMessage: errorMessage ?? this.errorMessage,
      phase: phase ?? this.phase,
      phaseDone: phaseDone ?? this.phaseDone,
      phaseTotal: phaseTotal ?? this.phaseTotal,
    );
  }
}

class SendQueueState {
  const SendQueueState({
    required this.recipient,
    required this.recipientLabel,
    required this.items,
    required this.currentIndex,
    required this.cancelled,
    this.quotaError,
    this.currentCancel,
  });

  final UserLookup recipient;
  final String recipientLabel;
  final List<QueuedSend> items;

  /// Index of the item the controller is currently working on. `-1`
  /// when the batch hasn't started yet OR every item has reached a
  /// terminal state.
  final int currentIndex;
  final bool cancelled;

  /// Batch-wide 402. When set, [items] has already been rewritten so
  /// the current item is `failed` with this exception's message and
  /// every remaining `pending` item is `cancelled`. The completion
  /// screen reads this to render the paywall CTA.
  final QuotaExceededException? quotaError;

  /// [CancelToken] for the currently-in-flight item. Non-null iff
  /// `isRunning`. Held on state (rather than in the controller) so
  /// the UI can render Cancel button state directly off the queue.
  final CancelToken? currentCancel;

  bool get isRunning => currentIndex >= 0 && currentIndex < items.length;
  bool get isDone => !isRunning;

  int get doneCount =>
      items.where((i) => i.status == QueueItemStatus.done).length;
  int get failedCount =>
      items.where((i) => i.status == QueueItemStatus.failed).length;
  int get cancelledCount =>
      items.where((i) => i.status == QueueItemStatus.cancelled).length;

  SendQueueState copyWith({
    List<QueuedSend>? items,
    int? currentIndex,
    bool? cancelled,
    QuotaExceededException? quotaError,
    CancelToken? currentCancel,
    bool clearCurrentCancel = false,
  }) {
    return SendQueueState(
      recipient: recipient,
      recipientLabel: recipientLabel,
      items: items ?? this.items,
      currentIndex: currentIndex ?? this.currentIndex,
      cancelled: cancelled ?? this.cancelled,
      quotaError: quotaError ?? this.quotaError,
      currentCancel:
          clearCurrentCancel ? null : (currentCancel ?? this.currentCancel),
    );
  }
}

final sendQueueProvider =
    NotifierProvider<SendQueueController, SendQueueState?>(
  SendQueueController.new,
);

class SendQueueController extends Notifier<SendQueueState?> {
  @override
  SendQueueState? build() => null;

  /// Kick off a batch. Async-returns when every item has reached a
  /// terminal state (done / failed / cancelled). The UI awaits this
  /// only if it wants an "all-done" callback; typically it just
  /// watches state.
  Future<void> start({
    required UserLookup recipient,
    required String recipientLabel,
    required List<PickedFile> files,
  }) async {
    if (state?.isRunning ?? false) {
      // A batch is already in flight. The screen shouldn't call this,
      // but defend against a double-tap on the Send button.
      return;
    }
    final items = <QueuedSend>[
      for (var i = 0; i < files.length; i++)
        QueuedSend(
          localId: 'queued-$i-${DateTime.now().microsecondsSinceEpoch}',
          file: files[i],
          status: QueueItemStatus.pending,
        ),
    ];
    state = SendQueueState(
      recipient: recipient,
      recipientLabel: recipientLabel,
      items: items,
      currentIndex: 0,
      cancelled: false,
    );

    final svc = await ref.read(transferServiceProvider.future);

    for (var i = 0; i < files.length; i++) {
      final snapshot = state;
      if (snapshot == null || snapshot.cancelled) break;
      await _sendOne(index: i, svc: svc);
      if (state?.cancelled ?? false) break;
      if (state?.quotaError != null) break;
    }

    // Batch is over — every subsequent item is already in a terminal
    // state. Clear currentIndex so the UI switches to summary mode.
    final finalState = state;
    if (finalState != null) {
      state = finalState.copyWith(
        currentIndex: -1,
        clearCurrentCancel: true,
      );
    }
  }

  Future<void> _sendOne({
    required int index,
    required TransferService svc,
  }) async {
    final cancel = CancelToken();
    final startSnapshot = state;
    if (startSnapshot == null) return;
    state = startSnapshot.copyWith(
      currentIndex: index,
      items: _updateItem(
        startSnapshot.items,
        index,
        (it) => it.copyWith(
          status: QueueItemStatus.encrypting,
          phase: SendPhase.encrypting,
          phaseDone: 0,
          phaseTotal: startSnapshot.items[index].file.length,
        ),
      ),
      currentCancel: cancel,
    );

    final file = startSnapshot.items[index].file;
    try {
      final result = await svc.send(
        mode: SendMode.app,
        recipient: startSnapshot.recipient,
        source: file.source,
        onProgress: (phase, done, total) {
          final snap = state;
          if (snap == null) return;
          state = snap.copyWith(
            items: _updateItem(
              snap.items,
              index,
              (it) => it.copyWith(
                status: phase == SendPhase.uploading
                    ? QueueItemStatus.uploading
                    : QueueItemStatus.encrypting,
                phase: phase,
                phaseDone: done,
                phaseTotal: total,
              ),
            ),
          );
        },
        cancel: cancel,
      );

      // Success — record + log to history.
      final okSnap = state;
      if (okSnap != null) {
        state = okSnap.copyWith(
          items: _updateItem(
            okSnap.items,
            index,
            (it) => it.copyWith(
              status: QueueItemStatus.done,
              transferId: result.transferId,
              byteCountOnServer: result.byteCountOnServer,
              phase: null,
              phaseDone: null,
              phaseTotal: null,
            ),
          ),
        );
      }
      await ref.read(transferHistoryProvider.notifier).log(
            SentHistoryEntry(
              transferId: result.transferId,
              timestamp: DateTime.now().toUtc(),
              filename: file.name,
              sizeBytes: file.length,
              mode: 'app',
              recipientLabel: startSnapshot.recipientLabel.isEmpty
                  ? null
                  : startSnapshot.recipientLabel,
              maxDownloads: 1,
              hasPassword: false,
            ),
          );
    } on SendCancelledException {
      final snap = state;
      if (snap == null) return;
      state = snap.copyWith(
        items: _updateItem(
          snap.items,
          index,
          (it) => it.copyWith(
            status: QueueItemStatus.cancelled,
            errorMessage: 'Cancelled',
          ),
        ),
      );
    } on QuotaExceededException catch (exc) {
      // Batch-wide: the balance is out. Fail the current item, mark
      // every subsequent pending item cancelled, surface the exception
      // for the completion screen's paywall CTA.
      final snap = state;
      if (snap == null) return;
      final updatedItems = _updateItem(
        snap.items,
        index,
        (it) => it.copyWith(
          status: QueueItemStatus.failed,
          errorMessage: exc.message,
        ),
      );
      final cancelledRest = <QueuedSend>[
        for (var i = 0; i < updatedItems.length; i++)
          if (i > index &&
              updatedItems[i].status == QueueItemStatus.pending)
            updatedItems[i].copyWith(
              status: QueueItemStatus.cancelled,
              errorMessage: 'Skipped — balance exhausted',
            )
          else
            updatedItems[i],
      ];
      state = snap.copyWith(
        items: cancelledRest,
        quotaError: exc,
      );
    } on ApiException catch (exc) {
      final snap = state;
      if (snap == null) return;
      state = snap.copyWith(
        items: _updateItem(
          snap.items,
          index,
          (it) => it.copyWith(
            status: QueueItemStatus.failed,
            errorMessage: exc.message,
          ),
        ),
      );
    } on Object catch (exc) {
      final snap = state;
      if (snap == null) return;
      state = snap.copyWith(
        items: _updateItem(
          snap.items,
          index,
          (it) => it.copyWith(
            status: QueueItemStatus.failed,
            errorMessage: 'Send failed: $exc',
          ),
        ),
      );
    } finally {
      final snap = state;
      if (snap != null) {
        state = snap.copyWith(clearCurrentCancel: true);
      }
    }
  }

  /// Cancel the in-flight file AND drop the queue. Per ADR-0009,
  /// cancelling almost always means "I don't want any of this
  /// anymore" — retrying individual failed items comes back from the
  /// completion screen.
  void cancel() {
    final snap = state;
    if (snap == null || !snap.isRunning) return;
    snap.currentCancel?.cancel();
    // Preemptively mark remaining pending items cancelled so the UI
    // updates even before the in-flight `send()` throws
    // SendCancelledException.
    state = snap.copyWith(
      cancelled: true,
      items: [
        for (final item in snap.items)
          if (item.status == QueueItemStatus.pending)
            item.copyWith(
              status: QueueItemStatus.cancelled,
              errorMessage: 'Cancelled',
            )
          else
            item,
      ],
    );
  }

  /// Drop the batch state entirely. The screen calls this after the
  /// user leaves the completion view (Done / Send more).
  void reset() {
    state = null;
  }

  List<QueuedSend> _updateItem(
    List<QueuedSend> items,
    int index,
    QueuedSend Function(QueuedSend) update,
  ) {
    return [
      for (var i = 0; i < items.length; i++)
        if (i == index) update(items[i]) else items[i],
    ];
  }
}
