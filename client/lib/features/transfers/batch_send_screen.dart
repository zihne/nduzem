import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/api_client.dart';
import 'send_queue.dart';

/// Batch send progress + completion surface (ADR-0009).
///
/// The screen is a pure reflection of [sendQueueProvider]: it never
/// starts a batch itself (the send screen does that + navigates
/// here). Two visual modes:
///
///   - `state.isRunning` — one file is encrypting/uploading right
///     now. Header shows "N of M · currentfile", the current-file
///     phase bar shows the existing single-file progress widget, and
///     the item list shows per-item status.
///   - `state.isDone` — every item has reached a terminal state.
///     The list morphs into a summary; primary CTA is "Done" (go
///     home), secondary is "Buy more credit" when a quota-exceeded
///     event ended the batch.
class BatchSendScreen extends ConsumerWidget {
  const BatchSendScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(sendQueueProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sending files'),
        // No back button while a batch is running — the user must
        // Cancel first. When done, the AppBar's back arrow returns
        // them to Home via the router.
        automaticallyImplyLeading: state?.isDone ?? true,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: state == null
              ? const Center(
                  child: Text(
                    'No batch in flight. Pick files on the send screen '
                    'to start one.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontStyle: FontStyle.italic),
                  ),
                )
              : _BatchBody(state: state),
        ),
      ),
    );
  }
}

class _BatchBody extends ConsumerWidget {
  const _BatchBody({required this.state});
  final SendQueueState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(state: state),
        const SizedBox(height: 12),
        if (state.isRunning) _CurrentFileProgress(state: state),
        const SizedBox(height: 12),
        Expanded(child: _ItemList(state: state)),
        const SizedBox(height: 12),
        _Footer(state: state),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.state});
  final SendQueueState state;

  @override
  Widget build(BuildContext context) {
    final total = state.items.length;
    final done = state.doneCount;
    final failed = state.failedCount;
    final cancelled = state.cancelledCount;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              state.isRunning
                  ? '${state.currentIndex + 1} of $total · '
                      '${state.items[state.currentIndex].file.name}'
                  : 'Batch complete',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Recipient: ${state.recipientLabel}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 12,
              children: [
                _Stat(label: 'Sent', value: done, color: scheme.primary),
                _Stat(label: 'Failed', value: failed, color: scheme.error),
                _Stat(
                  label: 'Cancelled',
                  value: cancelled,
                  color: scheme.onSurfaceVariant,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({
    required this.label,
    required this.value,
    required this.color,
  });
  final String label;
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Text(
      '$label: $value',
      style: TextStyle(color: color, fontWeight: FontWeight.w600),
    );
  }
}

/// Progress bar for the currently-running file. Mirrors the existing
/// single-file phase bar so the visual language is consistent across
/// single and batch sends.
class _CurrentFileProgress extends StatelessWidget {
  const _CurrentFileProgress({required this.state});
  final SendQueueState state;

  @override
  Widget build(BuildContext context) {
    final item = state.items[state.currentIndex];
    final phase = item.phase;
    final done = item.phaseDone ?? 0;
    final total = item.phaseTotal ?? 0;
    final value = total > 0 ? done / total : null;
    final label = switch (phase) {
      null => 'Preparing…',
      _ => _phaseLabel(phase),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 4),
        LinearProgressIndicator(value: value),
      ],
    );
  }

  String _phaseLabel(dynamic phase) {
    final name = phase.toString();
    if (name.endsWith('.encrypting')) return 'Encrypting';
    if (name.endsWith('.preparing')) return 'Preparing';
    if (name.endsWith('.uploading')) return 'Uploading';
    return 'Working';
  }
}

class _ItemList extends StatelessWidget {
  const _ItemList({required this.state});
  final SendQueueState state;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      itemCount: state.items.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) => _ItemTile(item: state.items[i]),
    );
  }
}

class _ItemTile extends StatelessWidget {
  const _ItemTile({required this.item});
  final QueuedSend item;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, iconColor, statusText) = switch (item.status) {
      QueueItemStatus.pending => (
        Icons.schedule,
        scheme.onSurfaceVariant,
        'Waiting',
      ),
      QueueItemStatus.encrypting => (
        Icons.lock_outline,
        scheme.primary,
        'Encrypting',
      ),
      QueueItemStatus.uploading => (
        Icons.cloud_upload_outlined,
        scheme.primary,
        'Uploading',
      ),
      QueueItemStatus.done => (
        Icons.check_circle,
        scheme.primary,
        'Sent',
      ),
      QueueItemStatus.failed => (Icons.error, scheme.error, 'Failed'),
      QueueItemStatus.cancelled => (
        Icons.block,
        scheme.onSurfaceVariant,
        'Cancelled',
      ),
    };
    final subtitle = item.errorMessage != null
        ? '$statusText · ${item.errorMessage}'
        : statusText;
    return ListTile(
      dense: true,
      leading: Icon(icon, color: iconColor),
      title: Text(
        item.file.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        subtitle,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

class _Footer extends ConsumerWidget {
  const _Footer({required this.state});
  final SendQueueState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (state.isRunning) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          OutlinedButton.icon(
            onPressed: () =>
                ref.read(sendQueueProvider.notifier).cancel(),
            icon: const Icon(Icons.cancel),
            label: const Text('Cancel batch'),
          ),
        ],
      );
    }
    // Batch done: paywall CTA if quota killed it, plus Done to leave.
    final quota = state.quotaError;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (quota != null) ...[
          _QuotaExceededBatchPanel(exception: quota),
          const SizedBox(height: 12),
        ],
        FilledButton.icon(
          onPressed: () {
            ref.read(sendQueueProvider.notifier).reset();
            context.go('/');
          },
          icon: const Icon(Icons.check),
          label: const Text('Done'),
        ),
      ],
    );
  }
}

/// Mirrors the send screen's single-file quota panel (ADR-0033) so a
/// batch that ran into 402 mid-way shows the same CTA. Message is
/// tailored to the batch case ("this batch stopped because...").
class _QuotaExceededBatchPanel extends StatelessWidget {
  const _QuotaExceededBatchPanel({required this.exception});
  final QuotaExceededException exception;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.wallet, color: scheme.onErrorContainer),
                const SizedBox(width: 8),
                Text(
                  'Batch stopped — not enough storage budget',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: scheme.onErrorContainer,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'The next file needed ${exception.requiredMb} MiB. You '
              'have ${exception.subRemainingMb} MiB left on your plan '
              'and ${exception.creditMb} MiB in credits. Remaining '
              'files were skipped — top up and re-send them.',
              style: TextStyle(color: scheme.onErrorContainer),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: () => context.push('/paywall'),
                icon: const Icon(Icons.add_shopping_cart),
                label: const Text('Buy more credit'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
