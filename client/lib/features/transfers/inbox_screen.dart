import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/api_client.dart';
import '../../api/transfers_api.dart';
import '../auth/auth_providers.dart';
import '../../widgets/max_width_content.dart';

/// Shows the caller's inbox — every uploaded transfer where they are the
/// recipient. Refreshes via a Riverpod FutureProvider; pull-to-refresh
/// invalidates it.
///
/// Alongside each transfer we surface whether the recipient has verified
/// the *sender's* fingerprint out-of-band via `/verify-contact`. That
/// lets the recipient decide before tapping whether to trust the content
/// or to go through OOB verification first.
///
/// The inbox response does NOT include `wrapped_key` (that requires a
/// /download call which increments the download counter), so we cannot
/// show real filenames here — only sender identity + byte count + expiry.

class InboxViewData {
  const InboxViewData({required this.items, required this.verifiedSenders});
  final List<InboxItem> items;

  /// Set of sender user_ids the recipient has verified OOB. Passed alongside
  /// the inbox items so the tile can render an `unknown` warning without
  /// each row firing its own async lookup.
  final Set<String> verifiedSenders;
}

final inboxProvider = FutureProvider.autoDispose<InboxViewData>((ref) async {
  final svc = await ref.watch(transferServiceProvider.future);
  final items = await svc.inbox();

  final verifiedRepo = ref.watch(verifiedContactsRepoProvider);
  final verified = <String>{};
  for (final item in items) {
    final sid = item.senderId;
    if (sid == null) continue;
    final vc = await verifiedRepo.read(sid);
    if (vc != null) verified.add(sid);
  }
  return InboxViewData(items: items, verifiedSenders: verified);
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
      body: MaxWidthContent(
          child: RefreshIndicator(
        onRefresh: () async => ref.invalidate(inboxProvider),
        child: inbox.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (err, _) => _ErrorView(error: err),
          data: (view) => view.items.isEmpty
              ? const _EmptyView()
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: view.items.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final item = view.items[i];
                    final verified = item.senderId != null &&
                        view.verifiedSenders.contains(item.senderId);
                    return _InboxTile(item: item, senderVerified: verified);
                  },
                ),
        ),
      ),),
    );
  }
}

class _InboxTile extends StatelessWidget {
  const _InboxTile({required this.item, required this.senderVerified});
  final InboxItem item;
  final bool senderVerified;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: CircleAvatar(
        backgroundColor:
            senderVerified ? scheme.primaryContainer : scheme.errorContainer,
        child: Icon(
          senderVerified ? Icons.verified_user : Icons.help_outline,
          color: senderVerified
              ? scheme.onPrimaryContainer
              : scheme.onErrorContainer,
        ),
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              _senderLabel(item),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${_bytes(item.byteCount)} · sent '
            '${_relative(item.createdAt)} · expires '
            '${_relative(item.expiresAt)}',
          ),
          const SizedBox(height: 2),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                  senderVerified ? Icons.check_circle : Icons.warning_amber,
                  size: 14,
                  color: senderVerified ? scheme.primary : scheme.error,
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  senderVerified
                      ? 'Verified sender'
                      : 'Unknown sender — verify their fingerprint '
                          'before trusting the file',
                  style: TextStyle(
                    fontSize: 12,
                    color: senderVerified ? scheme.primary : scheme.error,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
      isThreeLine: true,
      trailing: const Icon(Icons.chevron_right),
      onTap: () => context.push('/receive/${item.transferId}'),
    );
  }

  /// Prefer the sender's handle if we have it; fall back to a short
  /// form of the sender's user_id so the tile still identifies WHO sent
  /// the file, not just "someone". If neither is available (link-mode
  /// stub — M5 territory), say so.
  static String _senderLabel(InboxItem item) {
    final handle = item.senderHandle;
    if (handle != null && handle.isNotEmpty) return '@$handle';
    final id = item.senderId;
    if (id != null && id.isNotEmpty) {
      final short = id.length > 8 ? id.substring(0, 8) : id;
      return 'Sender $short…';
    }
    return 'Anonymous sender';
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
