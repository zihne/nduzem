import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'transfer_history_entry.dart';
import 'transfer_history_provider.dart';
import '../../widgets/max_width_content.dart';

/// Chronological list of local transfer history (ADR-0007).
///
/// Newest-first. Sent and received entries interleave in one list;
/// direction is shown by icon. Tap a row for the detail dialog. The
/// app-bar overflow exposes "Clear all" (guarded by a confirm dialog).
class TransferHistoryScreen extends ConsumerWidget {
  const TransferHistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(transferHistoryProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Transfer history'),
        actions: [
          async.maybeWhen(
            data: (entries) => entries.isEmpty
                ? const SizedBox.shrink()
                : IconButton(
                    tooltip: 'Clear all',
                    icon: const Icon(Icons.delete_sweep_outlined),
                    onPressed: () => _confirmClearAll(context, ref),
                  ),
            orElse: () => const SizedBox.shrink(),
          ),
        ],
      ),
      body: MaxWidthContent(
          child: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => Padding(
          padding: const EdgeInsets.all(16),
          child: Text('Could not read history: $err'),
        ),
        data: (entries) {
          if (entries.isEmpty) {
            return const _EmptyState();
          }
          return ListView.separated(
            itemCount: entries.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) => _HistoryTile(entry: entries[i]),
          );
        },
      ),),
    );
  }

  Future<void> _confirmClearAll(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear all history?'),
        content: const Text(
          'This wipes the local list on this device. Files already sent '
          'or received are not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(transferHistoryProvider.notifier).clearAll();
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.history,
              size: 56,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text(
              'No transfers yet',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            const Text(
              'Sent files and received files show up here after each '
              'successful transfer.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _HistoryTile extends ConsumerWidget {
  const _HistoryTile({required this.entry});
  final TransferHistoryEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final icon = switch (entry) {
      SentHistoryEntry() => Icons.upload,
      ReceivedHistoryEntry() => Icons.download,
    };
    return ListTile(
      leading: Icon(icon),
      title: Text(
        entry.filename,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${_counterpartyLabel(entry)} · ${_formatSize(entry.sizeBytes)} · '
        '${_formatTimestamp(entry.timestamp)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: () => showDialog<void>(
        context: context,
        builder: (dialogContext) => _DetailDialog(entry: entry),
      ),
    );
  }
}

/// Compact "who was on the other end" summary for the list row. The
/// arrow (leading icon) already communicates direction; this string
/// answers "to whom / from whom" at a glance.
String _counterpartyLabel(TransferHistoryEntry entry) {
  return switch (entry) {
    SentHistoryEntry(mode: 'link') => 'Link mode',
    SentHistoryEntry(:final recipientLabel) =>
      recipientLabel != null && recipientLabel.isNotEmpty
          ? 'To $recipientLabel'
          : 'To (unknown)',
    ReceivedHistoryEntry(:final senderHandle) when senderHandle != null =>
      'From @$senderHandle',
    ReceivedHistoryEntry(:final senderIdShort) when senderIdShort != null =>
      'From $senderIdShort',
    ReceivedHistoryEntry() => 'From (unknown)',
  };
}

class _DetailDialog extends ConsumerWidget {
  const _DetailDialog({required this.entry});
  final TransferHistoryEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = <(String, String)>[
      ('Transfer ID', entry.transferId),
      ('Filename', entry.filename),
      ('Size', _formatSize(entry.sizeBytes)),
      ('When', _formatTimestamp(entry.timestamp)),
      ...switch (entry) {
        SentHistoryEntry(:final mode, :final maxDownloads, :final hasPassword)
            when mode == 'link' =>
          [
            ('Direction', 'Sent (link mode)'),
            ('Max downloads', '$maxDownloads'),
            ('Password', hasPassword ? 'Yes' : 'No'),
          ],
        SentHistoryEntry(:final recipientLabel) => [
            ('Direction', 'Sent (app mode)'),
            ('Recipient', recipientLabel ?? '(unknown)'),
          ],
        ReceivedHistoryEntry(
          :final senderHandle,
          :final senderIdShort,
          :final signatureVerified,
          :final savedPath,
        ) =>
          [
            ('Direction', 'Received'),
            if (senderHandle != null) ('Sender', '@$senderHandle'),
            if (senderIdShort != null) ('Sender id', senderIdShort),
            ('Signature verified', signatureVerified ? 'Yes' : 'No'),
            if (savedPath != null) ('Saved to', savedPath),
          ],
      },
    ];
    return AlertDialog(
      title: const Text('Transfer details'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (label, value) in rows) ...[
              Text(label, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 2),
              SelectableText(value),
              const SizedBox(height: 12),
            ],
            Row(
              children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.copy),
                  label: const Text('Copy ID'),
                  onPressed: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    await Clipboard.setData(
                      ClipboardData(text: entry.transferId),
                    );
                    messenger.showSnackBar(
                      const SnackBar(
                        content: Text('Transfer ID copied.'),
                      ),
                    );
                  },
                ),
                const Spacer(),
                TextButton.icon(
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Remove'),
                  onPressed: () async {
                    final navigator = Navigator.of(context);
                    await ref
                        .read(transferHistoryProvider.notifier)
                        .remove(entry.transferId);
                    navigator.pop();
                  },
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

String _formatSize(int bytes) {
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final formatted = value >= 100 || unit == 0
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);
  return '$formatted ${units[unit]}';
}

String _formatTimestamp(DateTime ts) {
  final local = ts.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final entryDay = DateTime(local.year, local.month, local.day);
  final delta = today.difference(entryDay).inDays;
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  if (delta == 0) return 'Today $hh:$mm';
  if (delta == 1) return 'Yesterday $hh:$mm';
  if (delta < 7) return '$delta days ago, $hh:$mm';
  final y = local.year.toString().padLeft(4, '0');
  final mo = local.month.toString().padLeft(2, '0');
  final d = local.day.toString().padLeft(2, '0');
  return '$y-$mo-$d $hh:$mm';
}
