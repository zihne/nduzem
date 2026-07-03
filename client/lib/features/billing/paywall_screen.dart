import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart';
import '../../api/billing_api.dart';
import '../auth/auth_providers.dart';

/// M3.1/M3.2/M3.3 client-side surface — one screen that:
///
///   1. Shows the current balance (from `GET /v1/billing/balance`).
///   2. Lists the region+platform-scoped catalog
///      (`GET /v1/billing/catalog`).
///   3. Simulates a store purchase via the stub receipt path
///      (`POST /v1/billing/iap/verify` with `receipt=STUB:<sku>:<txn>`)
///      until real StoreKit / Play Billing plugins ship in a follow-up
///      branch. See ADR-0033 for why stubs are the shipping default
///      right now.
///
/// The "store" is inferred from `Platform.isIOS ? apple : google` so
/// the catalog we ask for matches what a real StoreKit/Play SDK would
/// see. Region is hard-coded to `US` here — a settings-driven override
/// lands with the M9.x settings surface.
class PaywallScreen extends ConsumerStatefulWidget {
  const PaywallScreen({super.key});

  @override
  ConsumerState<PaywallScreen> createState() => _PaywallScreenState();
}

class _PaywallScreenState extends ConsumerState<PaywallScreen> {
  // Local mutable copies so a successful purchase updates the UI
  // without re-fetching the catalog.
  BalanceSnapshot? _balance;
  CatalogResponse? _catalog;
  bool _loading = true;
  String? _error;
  String? _purchasingSku;

  static const String _defaultRegion = 'US';

  String get _platform => Platform.isIOS ? 'apple' : 'google';

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = await ref.read(billingApiProvider.future);
      final balance = await api.fetchBalance();
      final catalog = await api.fetchCatalog(
        region: _defaultRegion,
        platform: _platform,
      );
      if (!mounted) return;
      setState(() {
        _balance = balance;
        _catalog = catalog;
      });
    } on ApiException catch (exc) {
      if (mounted) setState(() => _error = exc.message);
    } on Object catch (exc) {
      if (mounted) setState(() => _error = 'Load failed: $exc');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _buy(CatalogProduct product) async {
    setState(() {
      _purchasingSku = product.sku;
      _error = null;
    });
    try {
      final api = await ref.read(billingApiProvider.future);
      // Stub receipt. When real StoreKit / Play Billing plugins wire up
      // in a follow-up branch, the receipt string is replaced with the
      // opaque payload the platform returned — the endpoint is
      // unchanged, so this call stays.
      final txn = _mintStubTxn();
      final receipt = 'STUB:${product.sku}:$txn';
      final res = await api.iapVerify(
        platform: _platform,
        productSku: product.sku,
        region: _defaultRegion,
        receipt: receipt,
      );
      if (!mounted) return;
      setState(() => _balance = res.balance);
      final scaffold = ScaffoldMessenger.of(context);
      scaffold.showSnackBar(
        SnackBar(
          content: Text(
            res.idempotentReplay
                ? 'Already granted (replay). Balance unchanged.'
                : 'Granted ${_mbLabel(res.mbGranted)}.',
          ),
        ),
      );
    } on ApiException catch (exc) {
      if (mounted) setState(() => _error = exc.message);
    } on Object catch (exc) {
      if (mounted) setState(() => _error = 'Purchase failed: $exc');
    } finally {
      if (mounted) setState(() => _purchasingSku = null);
    }
  }

  String _mintStubTxn() {
    // Bit of entropy so a rapid double-tap yields distinct rows on the
    // server — matches what a real store SDK would surface. If the user
    // wants to test the idempotency path directly, they can retry the
    // same purchase via the "Already-granted?" tap logic in the future.
    final rng = Random.secure();
    final bits = List<int>.generate(4, (_) => rng.nextInt(1 << 30));
    return 'stub-${bits.join('-')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Storage & credits')),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_balance != null) _BalanceCard(balance: _balance!),
            if (_loading && _balance == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 24),
            _CatalogSection(
              catalog: _catalog,
              onBuy: _buy,
              purchasingSku: _purchasingSku,
            ),
            const SizedBox(height: 24),
            const _StubNoticeCard(),
          ],
        ),
      ),
    );
  }
}

// --- widgets -------------------------------------------------------------

class _BalanceCard extends StatelessWidget {
  const _BalanceCard({required this.balance});
  final BalanceSnapshot balance;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Your allowance', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Tier: ${balance.subTier}',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'This cycle: '
              '${_mbLabel(balance.subMbUsed)} used / '
              '${_mbLabel(balance.subMbIncluded)}',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Prepaid credits: ${_mbLabel(balance.creditMb)}',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Total available: ${_mbLabel(balance.totalMbAvailable)}',
              style: theme.textTheme.titleSmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _CatalogSection extends StatelessWidget {
  const _CatalogSection({
    required this.catalog,
    required this.onBuy,
    required this.purchasingSku,
  });
  final CatalogResponse? catalog;
  final void Function(CatalogProduct) onBuy;
  final String? purchasingSku;

  @override
  Widget build(BuildContext context) {
    final c = catalog;
    if (c == null) return const SizedBox.shrink();
    if (c.products.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'Not available in your region.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
      );
    }
    final packs = c.products
        .where((p) => p.productType == 'credit_pack')
        .toList(growable: false);
    final subs = c.products
        .where((p) => p.productType == 'subscription')
        .toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (packs.isNotEmpty) ...[
          Text(
            'Credit packs',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          for (final p in packs)
            _ProductTile(
              product: p,
              busy: purchasingSku == p.sku,
              onBuy: () => onBuy(p),
            ),
        ],
        if (subs.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(
            'Subscriptions',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          for (final p in subs)
            _ProductTile(
              product: p,
              busy: purchasingSku == p.sku,
              onBuy: () => onBuy(p),
            ),
        ],
      ],
    );
  }
}

class _ProductTile extends StatelessWidget {
  const _ProductTile({
    required this.product,
    required this.busy,
    required this.onBuy,
  });
  final CatalogProduct product;
  final bool busy;
  final VoidCallback onBuy;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    product.name,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${_mbLabel(product.mbGranted)} · ${product.sku}',
                    style: const TextStyle(fontStyle: FontStyle.italic),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(
              _priceLabel(product.listPriceCents, product.currency),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(width: 12),
            FilledButton(
              onPressed: busy ? null : onBuy,
              child: busy
                  ? const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Buy'),
            ),
          ],
        ),
      ),
    );
  }
}

class _StubNoticeCard extends StatelessWidget {
  const _StubNoticeCard();

  @override
  Widget build(BuildContext context) {
    // No user-facing wording change when this becomes a real store: the
    // Buy button goes through StoreKit / Play Billing behind the scenes
    // and the /iap/verify call is identical. This notice disappears
    // when we stop shipping stub verifiers on the server (ADR-0033
    // "Open follow-ups").
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          'Development build: purchases go through a stub receipt path '
          'on the server (ADR-0033). Real StoreKit / Play Billing wires '
          'up in a future release.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    );
  }
}

// --- formatters ----------------------------------------------------------

String _mbLabel(int mb) {
  if (mb >= 1024) {
    final gib = mb / 1024;
    // Trim trailing zero on whole GiB (e.g. 50.0 → 50).
    final label = gib == gib.roundToDouble()
        ? gib.toStringAsFixed(0)
        : gib.toStringAsFixed(1);
    return '$label GiB';
  }
  return '$mb MiB';
}

String _priceLabel(int cents, String currency) {
  final major = cents ~/ 100;
  final minor = (cents % 100).toString().padLeft(2, '0');
  return '$major.$minor $currency';
}
