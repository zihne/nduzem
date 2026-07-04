import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:http/http.dart' as http;

import '../core/config.dart';

/// Structured error surfaced by [ApiClient]. HTTP failures + JSON-decode
/// failures + network exceptions all funnel through here so callers don't
/// need to distinguish `http.ClientException` from a 500 body.
class ApiException implements Exception {
  ApiException({
    required this.statusCode,
    required this.message,
    this.body,
  });

  final int statusCode; // 0 for pre-request / network failures
  final String message;
  final Map<String, dynamic>? body;

  @override
  String toString() => 'ApiException(status=$statusCode, message=$message)';
}

/// Network was unreachable — DNS failure, connection refused, TLS
/// reset, timeout, etc. Subclass of [ApiException] so existing catch
/// blocks pick up the friendly `.message` automatically; callers who
/// want to distinguish (e.g. offer a retry vs. suggest checking
/// credentials) can type-check for this class.
///
/// The `.message` is deliberately user-facing (kept short, no jargon)
/// so screens can render it verbatim without further wrapping. The
/// original driver's message is stashed on `technicalDetail` for
/// logging / debugging.
class NetworkUnreachableException extends ApiException {
  NetworkUnreachableException({this.technicalDetail})
      : super(
          statusCode: 0,
          message:
              "Couldn't reach the server. Check your connection and try again.",
        );

  final String? technicalDetail;

  @override
  String toString() =>
      'NetworkUnreachableException(detail=${technicalDetail ?? '(none)'})';
}

/// Translate a raw async operation's network failures into a
/// [NetworkUnreachableException]. Catches [http.ClientException],
/// [SocketException], and [TimeoutException] — the three classes of
/// "we couldn't reach the other side" that show up on the storage
/// upload/download path (which doesn't go through [ApiClient]).
///
/// Anything else propagates unchanged so callers still see the true
/// failure for non-network bugs.
Future<T> runWithNetworkErrorTranslation<T>(Future<T> Function() op) async {
  try {
    return await op();
  } on http.ClientException catch (exc) {
    throw NetworkUnreachableException(technicalDetail: exc.message);
  } on SocketException catch (exc) {
    throw NetworkUnreachableException(technicalDetail: exc.message);
  } on TimeoutException catch (exc) {
    throw NetworkUnreachableException(
      technicalDetail: exc.message ?? 'timeout',
    );
  }
}

/// Token-bearer supplier + refresher. The API client stays ignorant of *how*
/// tokens are stored (secure storage vs. in-memory for tests) — it just asks
/// for one, retries once on 401 after asking for a refresh, and reports back
/// when the refresh itself has failed so the auth layer can log the user out.
abstract class TokenSource {
  Future<String?> readAccessToken();

  /// Called on 401. Return the fresh access token, or `null` if refresh
  /// failed (in which case the request that triggered this is NOT retried
  /// and the caller is expected to bounce the user to the login screen).
  Future<String?> refreshAccessToken();
}

/// Minimal typed wrapper over `package:http`. Handles:
///
///   - joining the configured base URL to relative paths
///   - JSON encoding + decoding
///   - `Authorization: Bearer …` injection when a token is present
///   - one-shot retry on 401 through [TokenSource.refreshAccessToken]
///   - non-2xx / non-JSON responses funneled through [ApiException]
class ApiClient {
  ApiClient({
    required this.config,
    required this.tokenSource,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final AppConfig config;
  final TokenSource tokenSource;
  final http.Client _http;

  /// GET/POST/DELETE — one helper each — return the decoded JSON body.
  Future<Map<String, dynamic>> get(String path, {bool authed = false}) =>
      _send('GET', path, body: null, authed: authed);

  Future<Map<String, dynamic>> post(
    String path, {
    Map<String, dynamic>? body,
    bool authed = false,
  }) =>
      _send('POST', path, body: body, authed: authed);

  Future<Map<String, dynamic>> delete(String path, {bool authed = false}) =>
      _send('DELETE', path, body: null, authed: authed);

  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    required Map<String, dynamic>? body,
    required bool authed,
  }) async {
    final url = config.apiBaseUrl.resolve(path);
    final request = http.Request(method, url);
    request.headers['content-type'] = 'application/json';
    request.headers['accept'] = 'application/json';
    if (body != null) request.body = jsonEncode(body);

    if (authed) {
      final token = await tokenSource.readAccessToken();
      if (token != null) request.headers['authorization'] = 'Bearer $token';
    }

    final response = await _dispatch(request);
    // 401 path: refresh once, retry once, then give up.
    if (authed && response.statusCode == 401) {
      final refreshed = await tokenSource.refreshAccessToken();
      if (refreshed != null) {
        request.headers['authorization'] = 'Bearer $refreshed';
        final retry = await _dispatch(_clone(request));
        return _decode(retry);
      }
    }
    return _decode(response);
  }

  Future<http.Response> _dispatch(http.Request request) async {
    return runWithNetworkErrorTranslation(() async {
      final streamed = await _http.send(request);
      return http.Response.fromStream(streamed);
    });
  }

  Map<String, dynamic> _decode(http.Response response) {
    final decoded = response.body.isEmpty
        ? <String, dynamic>{}
        : _tryDecode(response.body);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return decoded;
    }
    final detail = decoded['detail'];
    final message = detail is String
        ? detail
        : 'HTTP ${response.statusCode}';
    throw ApiException(
      statusCode: response.statusCode,
      message: message,
      body: decoded,
    );
  }

  Map<String, dynamic> _tryDecode(String body) {
    try {
      final parsed = jsonDecode(body);
      if (parsed is Map<String, dynamic>) return parsed;
      return <String, dynamic>{'raw': parsed};
    } on FormatException {
      return <String, dynamic>{'raw': body};
    }
  }

  http.Request _clone(http.Request original) {
    final r = http.Request(original.method, original.url)
      ..headers.addAll(original.headers)
      ..body = original.body;
    return r;
  }

  void close() => _http.close();
}
