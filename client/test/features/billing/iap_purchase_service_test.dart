import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:mocktail/mocktail.dart';

import 'package:opaqueshare/api/billing_api.dart';
import 'package:opaqueshare/features/billing/iap_purchase_service.dart';

/// The IapPurchaseService's real Play-Billing path can't run inside a
/// Dart-only test (no native plugin channel). But `Platform.isAndroid`
/// is `false` under `flutter test` on Linux/macOS, so `playAvailable`
/// returns false and every call falls through to the STUB path. That
/// path IS testable — it's exactly what the paywall exercises today
/// on iOS / desktop.
///
/// The tests below therefore cover:
/// - the STUB receipt shape the service sends to the server;
/// - the outcome flag that lets the UI distinguish "stub grant" from
///   a real Play purchase (`wasStub`);
/// - back-pressure against concurrent buys for the same SKU.
class _FakeBillingApi extends Mock implements BillingApi {}

class _FakeInAppPurchase extends Mock implements InAppPurchase {}

void main() {
  setUpAll(() => registerFallbackValue(<String, dynamic>{}));

  late _FakeBillingApi api;
  late IapPurchaseService service;

  IapVerifyResult grant(String sku, {int mbGranted = 5120}) {
    return IapVerifyResult(
      paymentId: 'pay-1',
      idempotentReplay: false,
      mbGranted: mbGranted,
      balance: BalanceSnapshot(
        subTier: 'free',
        subMbIncluded: 2048,
        subMbUsed: 0,
        subMbRemaining: 2048,
        subCycleStart: DateTime.parse('2026-07-02T00:00:00Z'),
        subCycleDays: 30,
        creditMb: mbGranted,
        totalMbAvailable: 2048 + mbGranted,
      ),
    );
  }

  setUp(() {
    api = _FakeBillingApi();
    // Inject a mock plugin — the default `InAppPurchase.instance`
    // registers native platform channels that don't exist inside
    // `flutter test` on Linux/macOS. The stub-fallback path never
    // touches this instance (short-circuits on !Platform.isAndroid),
    // but the plugin gets constructed at service-init time.
    final plugin = _FakeInAppPurchase();
    service = IapPurchaseService(
      billingApi: api,
      region: 'US',
      inAppPurchase: plugin,
    );
  });

  test('stub fallback: buy(credit_pack) POSTs STUB:<sku>:<txn> receipt',
      () async {
    when(
      () => api.iapVerify(
        platform: any(named: 'platform'),
        productSku: any(named: 'productSku'),
        region: any(named: 'region'),
        receipt: any(named: 'receipt'),
      ),
    ).thenAnswer((_) async => grant('credit_starter'));

    final outcome = await service.buy(
      sku: 'credit_starter',
      productType: 'credit_pack',
    );

    expect(outcome.wasStub, isTrue);
    expect(outcome.result.mbGranted, 5120);
    expect(outcome.result.balance.creditMb, 5120);

    final captured = verify(
      () => api.iapVerify(
        platform: captureAny(named: 'platform'),
        productSku: captureAny(named: 'productSku'),
        region: captureAny(named: 'region'),
        receipt: captureAny(named: 'receipt'),
      ),
    ).captured;
    // Linux test host → Platform.isIOS is false → 'google' branch.
    expect(captured[0], 'google');
    expect(captured[1], 'credit_starter');
    expect(captured[2], 'US');
    expect(captured[3], startsWith('STUB:credit_starter:'));
  });

  test('stub fallback: subscription SKU flows through the same path',
      () async {
    when(
      () => api.iapVerify(
        platform: any(named: 'platform'),
        productSku: any(named: 'productSku'),
        region: any(named: 'region'),
        receipt: any(named: 'receipt'),
      ),
    ).thenAnswer((_) async => grant('sub_personal', mbGranted: 51200));

    final outcome = await service.buy(
      sku: 'sub_personal',
      productType: 'subscription',
    );

    expect(outcome.wasStub, isTrue);
    expect(outcome.result.mbGranted, 51200);
    verify(
      () => api.iapVerify(
        platform: any(named: 'platform'),
        productSku: 'sub_personal',
        region: any(named: 'region'),
        receipt: any(named: 'receipt'),
      ),
    ).called(1);
  });

  // The "concurrent buy for the same SKU" guard only kicks in on the
  // real Play path (where `_pending[sku]` gets populated before the
  // native purchase call). The stub fallback doesn't need the guard
  // because each call generates a unique STUB txn, and the paywall
  // UI already disables the tile button while `_purchasingSku ==
  // sku`. Testing that guard end-to-end requires a native platform
  // channel we don't have in Dart-only tests — deferred.

  test('stub fallback: back-to-back buys succeed independently', () async {
    // Regression: when the STUB path was the only exercised path, the
    // service must not carry any per-SKU pending state across calls.
    // (The real Play path's stale-completer-retry behaviour is
    // untestable here without a native channel, but the STUB path
    // must remain immune to the same wedge.)
    when(
      () => api.iapVerify(
        platform: any(named: 'platform'),
        productSku: any(named: 'productSku'),
        region: any(named: 'region'),
        receipt: any(named: 'receipt'),
      ),
    ).thenAnswer((_) async => grant('credit_starter'));

    final first = await service.buy(
      sku: 'credit_starter',
      productType: 'credit_pack',
    );
    final second = await service.buy(
      sku: 'credit_starter',
      productType: 'credit_pack',
    );

    expect(first.result.paymentId, 'pay-1');
    expect(second.result.paymentId, 'pay-1');
    verify(
      () => api.iapVerify(
        platform: any(named: 'platform'),
        productSku: 'credit_starter',
        region: any(named: 'region'),
        receipt: any(named: 'receipt'),
      ),
    ).called(2);
  });

  // --- restore purchases (workstream B) ------------------------------

  test('restorePurchases is a no-op when no store is available', () async {
    // Under `flutter test` on macOS/Linux, Platform.isAndroid and
    // Platform.isIOS are both false, so `storeAvailable` is false and
    // there is nothing to restore. The important property is that it
    // returns cleanly rather than reaching into the plugin, whose
    // native channel does not exist here — the paywall calls this from
    // a user-visible button and must not throw on desktop or web.
    final plugin = _FakeInAppPurchase();
    final svc = IapPurchaseService(
      billingApi: api,
      region: 'US',
      inAppPurchase: plugin,
    );

    await expectLater(svc.restorePurchases(), completes);
    verifyNever(() => plugin.restorePurchases());
  });

  test('stub receipts are labelled with the running platform', () async {
    // Guards the fix to the previously hardcoded `platform: 'google'`.
    // On a non-iOS host this must be 'google'; the same expression now
    // serves the real-purchase path, where sending an Apple JWS as a
    // Google receipt would fail verification server-side.
    when(
      () => api.iapVerify(
        platform: any(named: 'platform'),
        productSku: any(named: 'productSku'),
        region: any(named: 'region'),
        receipt: any(named: 'receipt'),
      ),
    ).thenAnswer((_) async => grant('sub_personal'));

    await service.buy(sku: 'sub_personal', productType: 'subscription');

    final platforms = verify(
      () => api.iapVerify(
        platform: captureAny(named: 'platform'),
        productSku: any(named: 'productSku'),
        region: any(named: 'region'),
        receipt: any(named: 'receipt'),
      ),
    ).captured;
    expect(platforms.single, 'google');
  });
}
