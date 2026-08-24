// Concurrent 401s must share ONE refresh, or a valid session is signed out.
//
// The server rotates refresh tokens on every use and treats reuse of an
// already-rotated token as theft: it revokes the entire token FAMILY and
// commits that before returning 401 (server `api/v1/auth.py`).
//
// So two concurrent refreshes are not merely wasteful. The first rotates
// and mints a replacement; the second replays the now-rotated token; the
// server revokes the whole family — including the replacement just
// minted — and the client signs out a session that was valid moments
// before.
//
// Concurrent 401s are ordinary: an app resume, or one screen firing
// several requests at once. Without single-flight this is a logout users
// hit regularly, and it looks random from the outside.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:nduzem/api/api_client.dart';
import 'package:nduzem/api/auth_api.dart';
import 'package:nduzem/api/users_api.dart';
import 'package:nduzem/crypto/keys.dart';
import 'package:nduzem/features/auth/auth_repository.dart';
import 'package:nduzem/storage/secure_storage.dart';

class _FakeApi extends Mock implements AuthApi {}

class _FakeUsersApi extends Mock implements UsersApi {}

class _FakeStore extends Mock implements SecureStore {}

class _FakeKeys extends Mock implements KeypairGenerator {}

void main() {
  late _FakeApi api;
  late _FakeStore store;
  late AuthRepository repo;

  setUp(() {
    api = _FakeApi();
    store = _FakeStore();
    repo = AuthRepository(
      api: api,
      usersApi: _FakeUsersApi(),
      storage: store,
      keys: _FakeKeys(),
    );
    registerFallbackValue(Uint8List(0));
    when(() => store.write(any(), any())).thenAnswer((_) async {});
    when(() => store.delete(any())).thenAnswer((_) async {});
    when(() => store.purgeSession()).thenAnswer((_) async {});
    // Order matters: a later `any()` stub shadows an earlier specific one,
    // so the general case must be registered FIRST.
    when(() => store.read(any())).thenAnswer((_) async => null);
    when(() => store.read(SecureStore.kRefreshToken))
        .thenAnswer((_) async => 'refresh-token-1');
  });

  test('concurrent refreshes make exactly ONE call to the refresh endpoint',
      () async {
    // A refresh that stays pending until we release it, so both callers
    // are genuinely in flight at once rather than running in sequence.
    final gate = Completer<TokenPair>();
    when(() => api.refresh(refreshToken: any(named: 'refreshToken')))
        .thenAnswer((_) => gate.future);

    final first = repo.refreshAccessToken();
    final second = repo.refreshAccessToken();

    gate.complete(
      const TokenPair(access: 'new-access', refresh: 'refresh-token-2'),
    );

    final results = await Future.wait([first, second]);

    verify(() => api.refresh(refreshToken: 'refresh-token-1')).called(1);
    expect(
      results,
      ['new-access', 'new-access'],
      reason: 'both callers must receive the result of the single refresh',
    );
  });

  test('a later refresh starts a new call once the first has settled',
      () async {
    // The guard must clear on completion — otherwise the first refresh is
    // cached forever and the session can never be renewed again.
    when(() => api.refresh(refreshToken: any(named: 'refreshToken')))
        .thenAnswer(
      (_) async => const TokenPair(access: 'a1', refresh: 'refresh-token-2'),
    );

    await repo.refreshAccessToken();
    await repo.refreshAccessToken();

    verify(() => api.refresh(refreshToken: any(named: 'refreshToken')))
        .called(2);
  });

  test('a failing refresh signs out once, not once per concurrent caller',
      () async {
    final gate = Completer<TokenPair>();
    when(() => api.refresh(refreshToken: any(named: 'refreshToken')))
        .thenAnswer((_) => gate.future);

    final first = repo.refreshAccessToken();
    final second = repo.refreshAccessToken();

    gate.completeError(
      ApiException(statusCode: 401, message: 'Refresh token revoked.'),
    );

    final results = await Future.wait([first, second]);

    expect(results, [null, null]);
    verify(() => store.purgeSession()).called(1);
  });
}
