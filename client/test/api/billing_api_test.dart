import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:opaqueshare/api/api_client.dart';
import 'package:opaqueshare/api/billing_api.dart';

class _FakeClient extends Mock implements ApiClient {}

void main() {
  setUpAll(() => registerFallbackValue(<String, dynamic>{}));

  late _FakeClient client;
  late BillingApi api;

  setUp(() {
    client = _FakeClient();
    api = BillingApi(client);
  });

  Map<String, dynamic> balanceJson({
    String tier = 'free',
    int subIncluded = 2048,
    int subUsed = 0,
    int credit = 0,
  }) =>
      {
        'sub_tier': tier,
        'sub_mb_included': subIncluded,
        'sub_mb_used': subUsed,
        'sub_mb_remaining': subIncluded - subUsed,
        'sub_cycle_start': '2026-07-02T00:00:00+00:00',
        'sub_cycle_days': 30,
        'credit_mb': credit,
        'total_mb_available': (subIncluded - subUsed) + credit,
      };

  group('/v1/billing/balance', () {
    test('fetchBalance decodes the M3.1 response shape', () async {
      when(() => client.get(any(), authed: any(named: 'authed')))
          .thenAnswer((_) async => balanceJson(subUsed: 100));

      final b = await api.fetchBalance();
      final captured = verify(
        () => client.get(captureAny(), authed: any(named: 'authed')),
      ).captured.single as String;
      expect(captured, '/v1/billing/balance');
      expect(b.subTier, 'free');
      expect(b.subMbUsed, 100);
      expect(b.subMbRemaining, 2048 - 100);
      expect(b.subCycleDays, 30);
    });
  });

  group('/v1/billing/catalog', () {
    test('fetchCatalog issues an authed GET with URL-encoded params',
        () async {
      when(() => client.get(any(), authed: any(named: 'authed'))).thenAnswer(
        (_) async => <String, dynamic>{
          'region': 'US',
          'platform': 'apple',
          'products': [
            {
              'id': 'p-1',
              'sku': 'credit_starter',
              'name': 'Starter',
              'product_type': 'credit_pack',
              'mb_granted': 5120,
              'list_price_cents': 199,
              'currency': 'USD',
            },
          ],
        },
      );

      final res = await api.fetchCatalog(region: 'US', platform: 'apple');
      final captured = verify(
        () => client.get(captureAny(), authed: any(named: 'authed')),
      ).captured.single as String;
      expect(captured, startsWith('/v1/billing/catalog?region=US'));
      expect(captured, contains('platform=apple'));
      expect(res.products, hasLength(1));
      expect(res.products.single.sku, 'credit_starter');
      expect(res.products.single.mbGranted, 5120);
      expect(res.products.single.currency, 'USD');
    });
  });

  group('/v1/billing/iap/verify', () {
    test('iapVerify posts platform+sku+region+receipt payload', () async {
      when(
        () => client.post(
          any(),
          body: any(named: 'body'),
          authed: any(named: 'authed'),
        ),
      ).thenAnswer(
        (_) async => <String, dynamic>{
          'payment_id': 'pay-1',
          'idempotent_replay': false,
          'mb_granted': 5120,
          'balance': balanceJson(credit: 5120),
        },
      );

      final res = await api.iapVerify(
        platform: 'apple',
        productSku: 'credit_starter',
        region: 'US',
        receipt: 'STUB:credit_starter:txn-42',
      );
      final captured = verify(
        () => client.post(
          '/v1/billing/iap/verify',
          body: captureAny(named: 'body'),
          authed: any(named: 'authed'),
        ),
      ).captured.single as Map<String, dynamic>;
      expect(captured['platform'], 'apple');
      expect(captured['product_sku'], 'credit_starter');
      expect(captured['region'], 'US');
      expect(captured['receipt'], 'STUB:credit_starter:txn-42');
      expect(res.paymentId, 'pay-1');
      expect(res.idempotentReplay, isFalse);
      expect(res.mbGranted, 5120);
      expect(res.balance.creditMb, 5120);
    });

    test('iapVerify surfaces idempotent replay flag', () async {
      when(
        () => client.post(
          any(),
          body: any(named: 'body'),
          authed: any(named: 'authed'),
        ),
      ).thenAnswer(
        (_) async => <String, dynamic>{
          'payment_id': 'pay-idem',
          'idempotent_replay': true,
          'mb_granted': 5120,
          'balance': balanceJson(credit: 5120),
        },
      );

      final res = await api.iapVerify(
        platform: 'apple',
        productSku: 'credit_starter',
        region: 'US',
        receipt: 'STUB:credit_starter:txn-idem',
      );
      expect(res.idempotentReplay, isTrue);
      expect(res.balance.creditMb, 5120);
    });
  });
}
