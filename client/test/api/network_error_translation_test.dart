import 'dart:async';
import 'dart:io' show SocketException;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:opaqueshare/api/api_client.dart';

void main() {
  group('NetworkUnreachableException', () {
    test('is a subclass of ApiException so existing catches pick it up',
        () {
      final exc = NetworkUnreachableException();
      expect(exc, isA<ApiException>());
    });

    test('shows a user-facing message and hides the driver string', () {
      final exc = NetworkUnreachableException(
        technicalDetail: 'ClientException: Connection reset by peer',
      );
      // .message is what screens render — no jargon, no URIs.
      expect(exc.message, isNot(contains('ClientException')));
      expect(exc.message, isNot(contains('http')));
      expect(exc.message, contains('Check your connection'));
      // The driver detail is still available for logs.
      expect(exc.technicalDetail, contains('Connection reset by peer'));
    });

    test('statusCode is 0 (pre-request failure marker)', () {
      final exc = NetworkUnreachableException();
      expect(exc.statusCode, 0);
    });
  });

  group('runWithNetworkErrorTranslation', () {
    test('passes through successful results', () async {
      final result = await runWithNetworkErrorTranslation<int>(
        () async => 42,
      );
      expect(result, 42);
    });

    test('translates http.ClientException to NetworkUnreachableException',
        () async {
      Future<int> failing() async {
        throw http.ClientException(
          'Connection refused',
          Uri.parse('http://example/'),
        );
      }

      await expectLater(
        runWithNetworkErrorTranslation(failing),
        throwsA(isA<NetworkUnreachableException>()),
      );
    });

    test('translates SocketException to NetworkUnreachableException',
        () async {
      Future<int> failing() async {
        throw const SocketException('Network is unreachable');
      }

      await expectLater(
        runWithNetworkErrorTranslation(failing),
        throwsA(isA<NetworkUnreachableException>()),
      );
    });

    test('translates TimeoutException to NetworkUnreachableException',
        () async {
      Future<int> failing() async {
        throw TimeoutException('slow', const Duration(seconds: 1));
      }

      await expectLater(
        runWithNetworkErrorTranslation(failing),
        throwsA(isA<NetworkUnreachableException>()),
      );
    });

    test('leaves non-network exceptions unchanged', () async {
      // A StateError (or any other Exception that isn't a
      // network-shaped one) must propagate as-is so bugs surface with
      // their real stack trace instead of being masked as a
      // misleading "check your connection" message.
      Future<int> failing() async {
        throw StateError('bug');
      }

      await expectLater(
        runWithNetworkErrorTranslation(failing),
        throwsA(isA<StateError>()),
      );
    });
  });
}
