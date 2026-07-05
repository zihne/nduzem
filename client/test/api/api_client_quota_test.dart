import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:opaqueshare/api/api_client.dart';
import 'package:opaqueshare/core/config.dart';

/// Test double that never has a token — we only exercise unauthed paths.
class _NoToken implements TokenSource {
  @override
  Future<String?> readAccessToken() async => null;
  @override
  Future<String?> refreshAccessToken() async => null;
}

ApiClient _client(MockClient mock) => ApiClient(
      config: AppConfig(apiBaseUrl: Uri.parse('http://test/')),
      tokenSource: _NoToken(),
      httpClient: mock,
    );

void main() {
  group('QuotaExceededException', () {
    test('is an ApiException so blanket catches still work', () {
      final exc = QuotaExceededException(
        requiredMb: 100,
        subRemainingMb: 0,
        creditMb: 0,
      );
      expect(exc, isA<ApiException>());
      expect(exc.statusCode, 402);
    });

    test('surfaces the three numbers in the user-facing message', () {
      final exc = QuotaExceededException(
        requiredMb: 5720,
        subRemainingMb: 200,
        creditMb: 0,
      );
      expect(exc.message, contains('5720'));
      expect(exc.message, contains('200'));
      expect(exc.message, contains('0'));
    });
  });

  group('ApiClient — 402 quota_exceeded translation', () {
    test('402 with quota_exceeded body throws QuotaExceededException',
        () async {
      final mock = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'detail': {
              'error': 'quota_exceeded',
              'required_mb': 5720,
              'sub_remaining_mb': 200,
              'credit_mb': 0,
            },
          }),
          402,
          headers: {'content-type': 'application/json'},
        );
      });

      await expectLater(
        _client(mock).post('/v1/transfers/x/commit'),
        throwsA(
          isA<QuotaExceededException>()
              .having((e) => e.requiredMb, 'requiredMb', 5720)
              .having((e) => e.subRemainingMb, 'subRemainingMb', 200)
              .having((e) => e.creditMb, 'creditMb', 0),
        ),
      );
    });

    test('402 with an unstructured detail falls back to plain ApiException',
        () async {
      // Guard against over-eager matching: if a future 402 arrives from
      // a different error class (e.g. hand-thrown HTTPException with a
      // string detail), it must NOT masquerade as a quota event and
      // trigger the paywall CTA.
      final mock = MockClient((request) async {
        return http.Response(
          jsonEncode({'detail': 'some other reason'}),
          402,
          headers: {'content-type': 'application/json'},
        );
      });

      await expectLater(
        _client(mock).post('/v1/transfers/x/commit'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 402)
              .having(
                (e) => e,
                'not a QuotaExceededException',
                isNot(isA<QuotaExceededException>()),
              ),
        ),
      );
    });

    test('non-402 with error==quota_exceeded also falls through', () async {
      // Only 402 counts. A 400/500 that happens to include
      // `error: "quota_exceeded"` in the body should not be treated as
      // a quota-CTA-worthy event.
      final mock = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'detail': {
              'error': 'quota_exceeded',
              'required_mb': 1,
              'sub_remaining_mb': 0,
              'credit_mb': 0,
            },
          }),
          500,
          headers: {'content-type': 'application/json'},
        );
      });

      await expectLater(
        _client(mock).post('/v1/transfers/x/commit'),
        throwsA(
          isA<ApiException>().having(
            (e) => e,
            'not a QuotaExceededException',
            isNot(isA<QuotaExceededException>()),
          ),
        ),
      );
    });
  });
}
