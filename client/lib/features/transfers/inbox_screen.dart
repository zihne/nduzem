import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/api_client.dart';
import '../../api/transfers_api.dart';
import '../auth/auth_providers.dart';

/// Shows the caller's inbox — every uploaded transfer where they are the
/// recipient. Refreshes via a Riverpod FutureProvider; pull-to-refresh
/// invalidates it.
///
/// The inbox response does NOT include `wrapped_key` (that requires a
/// /download call which increments the download counter), so we cannot
/// show real filenames here — only sender handle + byte count + expiry.
/// Tapping a row navigates to `/receive/:id`, which then downloads,
/// decrypts, and shows the real name before writing to disk.
final inboxProvider = FutureProvider.autoDispose<List<InboxItem>>((ref) async {
  final svc = await ref.watch(transferServiceProvider.future);
  return svc.inbox();
});

class InboxScreen extends ConsumerWidget {
  const InboxScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inbox = ref.watch(inboxProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Inbox'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: () => ref.invalidate(inboxProvider),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(inboxProvider),
        child: inbox.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (err, _) => _ErrorView(error: err),
          data: (items) => items.isEmpty
              ? const _EmptyView()
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) => _InboxTile(item: items[i]),
                ),
        ),
      ),
    );
  }
}

class _InboxTile extends StatelessWidget {
  const _InboxTile({required this.item});
  final InboxItem item;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: scheme.primaryContainer,
        child: Icon(Icons.mail_outline, color: scheme.onPrimaryContainer),
      ),
      title: Text(item.senderHandle ?? 'Unknown sender'),
      subtitle: Text(
        '${_bytes(item.byteCount)} · sent '
        '${_relative(item.createdAt)} · expires '
        '${_relative(item.expiresAt)}',
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => context.go('/receive/${item.transferId}'),
    );
  }

  static String _bytes(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KiB';
    return '${(n / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }

  static String _relative(DateTime t) {
    final delta = t.difference(DateTime.now());
    if (delta.isNegative) {
      final ago = -delta;
      if (ago.inMinutes < 60) return '${ago.inMinutes} min ago';
      if (ago.inHours < 24) return '${ago.inHours} h ago';
      return '${ago.inDays} d ago';
    }
    if (delta.inMinutes < 60) return 'in ${delta.inMinutes} min';
    if (delta.inHours < 24) return 'in ${delta.inHours} h';
    return 'in ${delta.inDays} d';
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView();
  @override
  Widget build(BuildContext context) => ListView(
        children: const [
          SizedBox(height: 120),
          Center(child: Icon(Icons.inbox_outlined, size: 64)),
          SizedBox(height: 16),
          Center(child: Text('No transfers waiting.')),
          SizedBox(height: 8),
          Center(
            child: Text(
              'Pull down to refresh.',
              style: TextStyle(fontStyle: FontStyle.italic),
            ),
          ),
        ],
      );
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error});
  final Object error;
  @override
  Widget build(BuildContext context) {
    final msg = error is ApiException
        ? (error as ApiException).message
        : error.toString();
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 80),
        const Icon(Icons.error_outline, size: 48),
        const SizedBox(height: 12),
        Text(
          'Could not load your inbox.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(msg, textAlign: TextAlign.center),
      ],
    );
  }
}
