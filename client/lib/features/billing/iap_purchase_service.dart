import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:in_app_purchase/in_app_purchase.dart';

import '../../api/billing_api.dart';

/// Play Billing state machine that survives paywall-screen disposal.
///
/// Owned by a Riverpod provider so a purchase started on the paywall
/// completes even if the user backs out mid-dialog. See ADR-0002 for
/// why the state machine can't live on the screen.
///
/// Behaviour matrix:
///
///   - **Android + Play available**  → real `in_app_purchase` flow.
///     `buyConsumable(autoConsume: false)` for credit packs;
///     `buyNonConsumable` for subscriptions. Server verifies before
///     we `completePurchase` — Play redelivers on next app open if
///     the server verification failed for any reason.
///   - **iOS / no-Play Android / desktop** → STUB path. Mints
///     `STUB:<sku>:<txn>` and POSTs to /iap/verify. Server accepts
///     stubs indefinitely per server ADR-0033.
///
/// The service exposes a single async `buy(sku, productType)` that
/// returns when the purchase is fully processed (server verified +
/// acknowledged), or throws on cancellation / failure.
class IapPurchaseService {
  IapPurchaseService({
    required BillingApi billingApi,
    required String region,
    InAppPurchase? inAppPurchase,
  })  : _billingApi = billingApi,
        _region = region,
        _iap = inAppPurchase ?? InAppPurchase.instance;

  final BillingApi _billingApi;
  final String _region;
  final InAppPurchase _iap;

  StreamSubscription<List<PurchaseDetails>>? _sub;
  bool _initialized = false;

  // One pending purchase per SKU. Concurrent buys for the same SKU
  // are refused up-front to keep the state machine deterministic.
  final Map<String, Completer<IapPurchaseOutcome>> _pending = {};

  // Cache of Play-known product details. Populated lazily by
  // `queryProducts`; used by `buy` to hand a `PurchaseParam` to the
  // plugin without hitting Play twice per purchase.
  final Map<String, ProductDetails> _productDetailsCache = {};

  /// True iff we should try the real Play Billing flow. Any other
  /// combination (iOS, desktop, Android without Play Store) falls
  /// back to the STUB receipt path — server accepts both.
  Future<bool> get playAvailable async {
    if (!Platform.isAndroid) return false;
    return _iap.isAvailable();
  }

  /// Subscribe to the purchase stream. Safe to call more than once.
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    if (!await playAvailable) return;
    _sub = _iap.purchaseStream.listen(
      _onPurchaseUpdate,
      onDone: () => _sub?.cancel(),
      onError: (Object _) {
        // Stream-level errors are surfaced per-purchase via
        // PurchaseDetails.status = error; this callback covers pipe
        // failures, which are non-recoverable.
      },
    );
  }

  /// Ask Play for product details for the given SKUs. Returns the
  /// subset Play recognises; SKUs missing from the return value are
  /// unavailable on this device (catalog / Play Console drift). No-op
  /// (returns empty map) on platforms without Play.
  Future<Map<String, ProductDetails>> queryProducts(
    Iterable<String> skus,
  ) async {
    if (!await playAvailable) return const {};
    final skuSet = skus.toSet();
    final resp = await _iap.queryProductDetails(skuSet);
    for (final p in resp.productDetails) {
      _productDetailsCache[p.id] = p;
    }
    return {for (final p in resp.productDetails) p.id: p};
  }

  /// Start a purchase. Awaits the full flow: Play dialog → server
  /// verification → acknowledgement. Returns the granted balance on
  /// success. Throws on cancellation / server error / Play refusal.
  ///
  /// **Retry semantics.** A repeat `buy(sku)` while a prior purchase
  /// for the same SKU is still pending retires the stale completer
  /// with an error and proceeds with a fresh attempt. Rationale: Play
  /// Billing does not reliably emit a `PurchaseStatus.canceled` event
  /// when the user dismisses the Play sheet by tapping outside or
  /// swiping down — the stream stays quiet. Without this behaviour,
  /// one silent dismissal would wedge the SKU until the app restarts.
  /// Rapid double-tap protection is a UI concern; the paywall
  /// disables its button while awaiting `buy()`.
  Future<IapPurchaseOutcome> buy({
    required String sku,
    required String productType,
  }) async {
    final stale = _pending.remove(sku);
    if (stale != null && !stale.isCompleted) {
      stale.completeError(
        StateError('Purchase superseded by a fresh buy() call.'),
      );
    }
    if (!await playAvailable) {
      return _buyStub(sku: sku, productType: productType);
    }
    await initialize();

    var details = _productDetailsCache[sku];
    if (details == null) {
      final fetched = await queryProducts({sku});
      details = fetched[sku];
      if (details == null) {
        throw StateError(
          'Product $sku is not available on Play for this device.',
        );
      }
    }

    final completer = Completer<IapPurchaseOutcome>();
    _pending[sku] = completer;

    final param = PurchaseParam(productDetails: details);
    bool started;
    try {
      if (productType == 'credit_pack') {
        // autoConsume=false because we must let the server verify
        // BEFORE Play consumes the token; otherwise the token is
        // stale by the time /iap/verify runs.
        started = await _iap.buyConsumable(
          purchaseParam: param,
          autoConsume: false,
        );
      } else {
        started = await _iap.buyNonConsumable(purchaseParam: param);
      }
    } on Object {
      _pending.remove(sku);
      rethrow;
    }
    if (!started) {
      _pending.remove(sku);
      throw StateError('Play Billing refused to start the purchase.');
    }
    return completer.future;
  }

  Future<void> _onPurchaseUpdate(List<PurchaseDetails> updates) async {
    for (final purchase in updates) {
      switch (purchase.status) {
        case PurchaseStatus.pending:
          // Nothing to do — the terminal status update will follow.
          break;
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          await _processGranted(purchase);
          break;
        case PurchaseStatus.canceled:
          _pending.remove(purchase.productID)?.completeError(
                StateError('Purchase canceled.'),
              );
          if (purchase.pendingCompletePurchase) {
            await _iap.completePurchase(purchase);
          }
          break;
        case PurchaseStatus.error:
          _pending.remove(purchase.productID)?.completeError(
                StateError(
                  'Purchase failed: ${purchase.error?.message ?? 'unknown'}',
                ),
              );
          if (purchase.pendingCompletePurchase) {
            await _iap.completePurchase(purchase);
          }
          break;
      }
    }
  }

  Future<void> _processGranted(PurchaseDetails purchase) async {
    IapPurchaseOutcome? outcome;
    Object? error;
    try {
      final token = purchase.verificationData.serverVerificationData;
      final res = await _billingApi.iapVerify(
        platform: 'google',
        productSku: purchase.productID,
        region: _region,
        receipt: token,
      );
      outcome = IapPurchaseOutcome(result: res, wasStub: false);
    } on Object catch (exc) {
      error = exc;
    }

    if (error == null && purchase.pendingCompletePurchase) {
      // Acknowledge AFTER server accepts. If the server ever rejected
      // this receipt, we skip completePurchase and Play redelivers
      // on next app open — server idempotency handles that retry
      // correctly (server ADR-0033).
      await _iap.completePurchase(purchase);
    }

    final completer = _pending.remove(purchase.productID);
    if (completer == null) {
      // Recovery-path redelivery: purchase arrived when nobody was
      // waiting (e.g. app was killed mid-purchase). Server already
      // verified + we acknowledged above, so nothing further needed.
      return;
    }
    if (error == null) {
      completer.complete(outcome!);
    } else {
      completer.completeError(error);
    }
  }

  Future<IapPurchaseOutcome> _buyStub({
    required String sku,
    required String productType,
  }) async {
    final txn = _mintStubTxn();
    final receipt = 'STUB:$sku:$txn';
    // Server routes on `platform` — iOS uses the Apple stub, Android
    // without Play uses the Google stub, both accept STUB:*.
    final platform = Platform.isIOS ? 'apple' : 'google';
    final res = await _billingApi.iapVerify(
      platform: platform,
      productSku: sku,
      region: _region,
      receipt: receipt,
    );
    return IapPurchaseOutcome(result: res, wasStub: true);
  }

  String _mintStubTxn() {
    final rng = Random.secure();
    final bits = List<int>.generate(4, (_) => rng.nextInt(1 << 30));
    return 'stub-${bits.join('-')}';
  }

  void dispose() {
    _sub?.cancel();
  }
}

/// Result of a successful `IapPurchaseService.buy(...)`. `wasStub` is
/// exposed so the paywall UI can distinguish "real Play purchase, keep
/// the confetti tasteful" from "dev-mode stub, note the fact". Both
/// carry the same server-side balance mutation.
class IapPurchaseOutcome {
  const IapPurchaseOutcome({required this.result, required this.wasStub});
  final IapVerifyResult result;
  final bool wasStub;
}
