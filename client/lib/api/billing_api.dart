import 'api_client.dart';

/// `/v1/billing/*` client (M3.1 balance + M3.2 catalog + M3.3 IAP verify).
///
/// The server treats the store receipt as opaque bytes and routes to a
/// per-platform verifier. While the M3.3 foundation slice is live
/// (ADR-0033), only stub receipts of the form
/// `STUB:<product_sku>:<transaction_id>` are accepted — anything else
/// yields HTTP 501 until real Apple / Google verification wires up.
class BillingApi {
  const BillingApi(this._client);
  final ApiClient _client;

  Future<BalanceSnapshot> fetchBalance() async {
    final body = await _client.get('/v1/billing/balance', authed: true);
    return BalanceSnapshot.fromJson(body);
  }

  Future<CatalogResponse> fetchCatalog({
    required String region,
    required String platform,
  }) async {
    final body = await _client.get(
      '/v1/billing/catalog'
      '?region=${Uri.encodeQueryComponent(region)}'
      '&platform=${Uri.encodeQueryComponent(platform)}',
      authed: true,
    );
    return CatalogResponse.fromJson(body);
  }

  /// Verify a store receipt and grant credit / update subscription.
  ///
  /// Idempotent on `(platform, transactionId)` — a client retry after a
  /// network hiccup returns the same `paymentId` with
  /// `idempotentReplay: true` and does NOT mutate the balance a second
  /// time. Callers treat both branches identically.
  Future<IapVerifyResult> iapVerify({
    required String platform,
    required String productSku,
    required String region,
    required String receipt,
  }) async {
    final body = await _client.post(
      '/v1/billing/iap/verify',
      authed: true,
      body: {
        'platform': platform,
        'product_sku': productSku,
        'region': region,
        'receipt': receipt,
      },
    );
    return IapVerifyResult.fromJson(body);
  }
}

// --- balance ------------------------------------------------------------

class BalanceSnapshot {
  const BalanceSnapshot({
    required this.subTier,
    required this.subMbIncluded,
    required this.subMbUsed,
    required this.subMbRemaining,
    required this.subCycleStart,
    required this.subCycleDays,
    required this.creditMb,
    required this.totalMbAvailable,
  });

  final String subTier;
  final int subMbIncluded;
  final int subMbUsed;
  final int subMbRemaining;
  final DateTime subCycleStart;
  final int subCycleDays;
  final int creditMb;
  final int totalMbAvailable;

  static BalanceSnapshot fromJson(Map<String, dynamic> m) => BalanceSnapshot(
        subTier: m['sub_tier'] as String,
        subMbIncluded: (m['sub_mb_included'] as num).toInt(),
        subMbUsed: (m['sub_mb_used'] as num).toInt(),
        subMbRemaining: (m['sub_mb_remaining'] as num).toInt(),
        subCycleStart: DateTime.parse(m['sub_cycle_start'] as String),
        subCycleDays: (m['sub_cycle_days'] as num).toInt(),
        creditMb: (m['credit_mb'] as num).toInt(),
        totalMbAvailable: (m['total_mb_available'] as num).toInt(),
      );
}

// --- catalog ------------------------------------------------------------

class CatalogResponse {
  const CatalogResponse({
    required this.region,
    required this.platform,
    required this.products,
  });

  final String region;
  final String platform;
  final List<CatalogProduct> products;

  static CatalogResponse fromJson(Map<String, dynamic> m) => CatalogResponse(
        region: m['region'] as String,
        platform: m['platform'] as String,
        products: (m['products'] as List<dynamic>)
            .cast<Map<String, dynamic>>()
            .map(CatalogProduct.fromJson)
            .toList(growable: false),
      );
}

class CatalogProduct {
  const CatalogProduct({
    required this.id,
    required this.sku,
    required this.name,
    required this.productType,
    required this.mbGranted,
    required this.listPriceCents,
    required this.currency,
  });

  final String id;
  final String sku;
  final String name;

  /// `credit_pack` or `subscription`. Kept as a plain string rather
  /// than an enum so an unknown value from a newer server doesn't crash
  /// old clients; the UI branches on the two known values and falls
  /// back to a generic "buy" affordance otherwise.
  final String productType;
  final int mbGranted;
  final int listPriceCents;
  final String currency;

  static CatalogProduct fromJson(Map<String, dynamic> m) => CatalogProduct(
        id: m['id'] as String,
        sku: m['sku'] as String,
        name: m['name'] as String,
        productType: m['product_type'] as String,
        mbGranted: (m['mb_granted'] as num).toInt(),
        listPriceCents: (m['list_price_cents'] as num).toInt(),
        currency: m['currency'] as String,
      );
}

// --- iap/verify ---------------------------------------------------------

class IapVerifyResult {
  const IapVerifyResult({
    required this.paymentId,
    required this.idempotentReplay,
    required this.mbGranted,
    required this.balance,
  });

  final String paymentId;

  /// True when the server found an existing payment for the same
  /// `(platform, transactionId)` and did NOT mutate the balance again.
  /// The returned `balance` is still the current authoritative state.
  final bool idempotentReplay;
  final int mbGranted;
  final BalanceSnapshot balance;

  static IapVerifyResult fromJson(Map<String, dynamic> m) => IapVerifyResult(
        paymentId: m['payment_id'] as String,
        idempotentReplay: m['idempotent_replay'] as bool? ?? false,
        mbGranted: (m['mb_granted'] as num).toInt(),
        balance: BalanceSnapshot.fromJson(
          m['balance'] as Map<String, dynamic>,
        ),
      );
}
