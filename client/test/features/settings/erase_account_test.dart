// Account erasure at the repository layer.
//
// The server is what actually erases the account; that is tested there.
// What this file covers is the part only the client can get wrong —
// the order of the server call and the local teardown, and how much
// local state the teardown takes.
//
// Both mistakes available here destroy user data on a request that did
// not succeed, so each has a test that fails if the ordering or the
// choice of purge is changed.
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:opaqueshare/api/api_client.dart';
import 'package:opaqueshare/api/auth_api.dart';
import 'package:opaqueshare/api/users_api.dart';
import 'package:opaqueshare/crypto/keys.dart';
import 'package:opaqueshare/features/auth/auth_repository.dart';
import 'package:opaqueshare/storage/secure_storage.dart';

import '../../crypto/sodium_test_support.dart';

class _FakeApi extends Mock implements AuthApi {}

class _FakeUsersApi extends Mock implements UsersApi {}

class _FakeStore extends Mock implements SecureStore {}

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();

  final maybeSodium = await tryInitSodium();
  final skipReason = sodiumSkipReason(maybeSodium);
  late final KeypairGenerator keys;
  if (maybeSodium != null) {
    keys = KeypairGenerator(maybeSodium);
  }

  group(
    'erasure',
    () {
      late _FakeApi api;
      late _FakeUsersApi usersApi;
      late _FakeStore store;
      late AuthRepository repo;

      final receipt = ErasureReceipt(
        erasedAt: DateTime.utc(2026, 8, 10),
        pendingTransfersBurned: 2,
        retainedNotice: 'Audit records are retained.',
      );

      setUp(() {
        api = _FakeApi();
        usersApi = _FakeUsersApi();
        store = _FakeStore();
        repo = AuthRepository(
          api: api,
          usersApi: usersApi,
          storage: store,
          keys: keys,
        );
        when(() => store.read(any())).thenAnswer((_) async => null);
        when(() => store.purgeAll()).thenAnswer((_) async {});
        when(() => store.purgeSession()).thenAnswer((_) async {});
      });

      test('a successful erasure returns the receipt', () async {
        when(() => usersApi.eraseAccount(password: any(named: 'password')))
            .thenAnswer((_) async => receipt);

        final result = await repo.eraseAccount(password: 'pw');

        expect(result.pendingTransfersBurned, 2);
        expect(result.retainedNotice, 'Audit records are retained.');
      });

      test('a successful erasure destroys the keypair, not just tokens',
          () async {
        // purgeSession leaves the identity keypair on the device so a
        // user can sign back in and still read their mail. After erasure
        // there is no account to sign back in to, and keeping private
        // keys on a device whose owner just asked us to delete
        // everything is not something we should be doing.
        when(() => usersApi.eraseAccount(password: any(named: 'password')))
            .thenAnswer((_) async => receipt);

        await repo.eraseAccount(password: 'pw');

        verify(() => store.purgeAll()).called(1);
        verifyNever(() => store.purgeSession());
      });

      test('a rejected erasure leaves local state completely untouched',
          () async {
        // The one that matters. If teardown ran before the request — or
        // ran regardless of its outcome — then a wrong password, a
        // dropped connection, or a moderation hold would destroy the
        // user's identity keys for an erasure that never happened,
        // making every transfer ever sent to them unreadable while their
        // account carried on existing.
        when(() => usersApi.eraseAccount(password: any(named: 'password')))
            .thenThrow(
          ApiException(statusCode: 401, message: 'Password does not match.'),
        );

        await expectLater(
          repo.eraseAccount(password: 'wrong'),
          throwsA(isA<ApiException>()),
        );

        verifyNever(() => store.purgeAll());
        verifyNever(() => store.purgeSession());
      });

      test('a moderation hold propagates the server reason verbatim',
          () async {
        // 403 means an abuse investigation is open and erasure is
        // withheld under GDPR Art. 17(3)(e). The user can act on that —
        // they are told to contact support — so the text has to survive
        // the trip to the UI rather than being flattened into a generic
        // failure.
        when(() => usersApi.eraseAccount(password: any(named: 'password')))
            .thenThrow(
          ApiException(
            statusCode: 403,
            message: 'Erasure is not available while the account is under '
                'moderation review. Contact support to appeal.',
          ),
        );

        await expectLater(
          repo.eraseAccount(password: 'pw'),
          throwsA(
            isA<ApiException>()
                .having((e) => e.statusCode, 'statusCode', 403)
                .having(
                  (e) => e.message,
                  'message',
                  contains('moderation review'),
                ),
          ),
        );
        verifyNever(() => store.purgeAll());
      });
    },
    skip: skipReason,
  );
}
