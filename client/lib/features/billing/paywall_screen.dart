import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../api/api_client.dart';
import '../../api/billing_api.dart';
import '../auth/auth_providers.dart';
import 'iap_purchase_service.dart';
import '../../widgets/max_width_content.dart';

/// M3.1/M3.2/M3.3 client-side surface — one screen that:
///
///   1. Shows the current balance (from `GET /v1/billing/balance`).
///   2. Lists the region+platform-scoped catalog
///      (`GET /v1/billing/catalog`).
///   3. Starts a purchase via [IapPurchaseService], which picks the
///      real Play Billing flow (Android with Play Store) or the
///      `STUB:<sku>:<txn>` fallback path (iOS / no-Play / desktop).
///
/// The state machine for a purchase lives in the service, not the
/// screen — so backing out of the paywall mid-purchase doesn't leak
/// the acknowledgement. See ADR-0002.
///
/// Region is hard-coded to `US` for v1 — a settings-driven override
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
  // SKUs Play recognises on this device. Empty when we're on the STUB
  // fallback path (iOS / no-Play). Populated on Android from
  // `IapPurchaseService.queryProducts` after we know the catalog.
  Set<String> _playAvailableSkus = const {};
  bool _usingStubFlow = true;
  bool _loading = true;
  String? _error;
  String? _purchasingSku;

  static const String _defaultRegion = 'US';

  // Catalog fetch uses whichever storefront actually applies on this
  // device. iOS falls into "apple"; web + Android + desktop go
  // "google" (server accepts STUB regardless). `dart:io`'s `Platform`
  // throws on web, so gate the probe with `kIsWeb`.
  String get _platform => (!kIsWeb && Platform.isIOS) ? 'apple' : 'google';

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
      final service = await ref.read(iapPurchaseServiceProvider.future);
      final balance = await api.fetchBalance();
      final catalog = await api.fetchCatalog(
        region: _defaultRegion,
        platform: _platform,
      );

      final playAvailable = await service.playAvailable;
      Set<String> playSkus = const {};
      if (playAvailable) {
        final catalogSkus = catalog.products.map((p) => p.sku).toSet();
        final products = await service.queryProducts(catalogSkus);
        playSkus = products.keys.toSet();
      }

      if (!mounted) return;
      setState(() {
        _balance = balance;
        _catalog = catalog;
        _playAvailableSkus = playSkus;
        _usingStubFlow = !playAvailable;
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
      final service = await ref.read(iapPurchaseServiceProvider.future);
      final outcome = await service.buy(
        sku: product.sku,
        productType: product.productType,
      );
      if (!mounted) return;
      setState(() => _balance = outcome.result.balance);
      final scaffold = ScaffoldMessenger.of(context);
      scaffold.showSnackBar(
        SnackBar(
          content: Text(
            outcome.result.idempotentReplay
                ? 'Already granted (replay). Balance unchanged.'
                : _grantMessage(outcome),
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

  String _grantMessage(IapPurchaseOutcome outcome) {
    final mb = _mbLabel(outcome.result.mbGranted);
    if (outcome.wasStub) {
      return 'Granted $mb (stub — no real payment).';
    }
    return 'Granted $mb.';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Storage & credits')),
      body: MaxWidthContent(
          child: RefreshIndicator(
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
            // Web has no Play Billing / StoreKit — nudge users to the
            // mobile app for purchases. Google/Apple's IAP handles
            // tax remittance in most jurisdictions so keeping the
            // purchase flow mobile-only sidesteps a stack of VAT/GST
            // compliance work. Balance card above still shows so web
            // users can see what they have.
            if (kIsWeb)
              const _MobileAppNudgeCard()
            else ...[
              _CatalogSection(
                catalog: _catalog,
                playAvailableSkus: _playAvailableSkus,
                onBuy: _buy,
                purchasingSku: _purchasingSku,
              ),
              const SizedBox(height: 24),
              _ModeNoticeCard(usingStubFlow: _usingStubFlow),
            ],
          ],
        ),
      ),),
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
    required this.playAvailableSkus,
    required this.onBuy,
    required this.purchasingSku,
  });
  final CatalogResponse? catalog;

  /// SKUs Play knows about. Empty when we're on the stub fallback
  /// (iOS / no-Play) — tiles render as normal, since the STUB path
  /// works for all of them.
  final Set<String> playAvailableSkus;
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

    Widget tile(CatalogProduct p) {
      // On Android with Play, a SKU missing from `playAvailableSkus`
      // means catalog / Play Console drift — grey out the Buy button
      // so the user gets a clear "not available on this device"
      // signal. On iOS / no-Play we take the STUB path uniformly.
      final onPlayFlow = playAvailableSkus.isNotEmpty;
      final unavailable = onPlayFlow && !playAvailableSkus.contains(p.sku);
      return _ProductTile(
        product: p,
        busy: purchasingSku == p.sku,
        unavailable: unavailable,
        onBuy: unavailable ? null : () => onBuy(p),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (packs.isNotEmpty) ...[
          Text(
            'Credit packs',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          for (final p in packs) tile(p),
        ],
        if (subs.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(
            'Subscriptions',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          for (final p in subs) tile(p),
        ],
      ],
    );
  }
}

class _ProductTile extends StatelessWidget {
  const _ProductTile({
    required this.product,
    required this.busy,
    required this.unavailable,
    required this.onBuy,
  });
  final CatalogProduct product;
  final bool busy;
  final bool unavailable;

  /// null when the tile is disabled (currently `unavailable == true`
  /// is the only case).
  final VoidCallback? onBuy;

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
                    _subtitleFor(product),
                    style: const TextStyle(fontStyle: FontStyle.italic),
                  ),
                  if (unavailable) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Not available on this device',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 12,
                      ),
                    ),
                  ],
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
              onPressed: (busy || onBuy == null) ? null : onBuy,
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

class _ModeNoticeCard extends StatelessWidget {
  const _ModeNoticeCard({required this.usingStubFlow});
  final bool usingStubFlow;

  @override
  Widget build(BuildContext context) {
    final text = usingStubFlow
        ? 'Development mode: purchases go through a stub receipt path '
            "on the server (won't charge you). Real StoreKit lands with "
            'Apple live verification.'
        : 'Real Play Billing purchases are active on this device. '
            'Test-tier tokens are used with sandbox / license-tester '
            "accounts and won't charge real money.";
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          text,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    );
  }
}

/// Web paywall body — Play Billing / StoreKit don't exist in the
/// browser, so instead of the STUB purchase flow we point users at
/// the mobile app where real IAP works. Google + Apple handle tax
/// remittance for us there.
class _MobileAppNudgeCard extends StatelessWidget {
  const _MobileAppNudgeCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.smartphone_outlined,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  'Buy credits in the mobile app',
                  style: theme.textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'Web sends work exactly the same as mobile — same '
              'end-to-end encryption, same recipient flow. But purchases '
              "live in the mobile app so Google and Apple's in-app "
              'purchase handles VAT / sales tax for you.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            Text(
              'Install OpaqueShare on Android or iOS, sign in with the '
              'same account, top up your credits there — the balance '
              'shows up here on your next page load.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

// --- formatters ----------------------------------------------------------

/// Tile subtitle: size + billing model. Never surface the raw SKU
/// (developer trivia — confuses buyers). The "· one-time" and
/// "/ month" tails also disambiguate credit vs subscription for a
/// user skimming without reading the section header.
String _subtitleFor(CatalogProduct p) {
  final size = _mbLabel(p.mbGranted);
  return switch (p.productType) {
    'credit_pack' => '$size · one-time top-up',
    'subscription' => '$size / month',
    _ => size,
  };
}

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
