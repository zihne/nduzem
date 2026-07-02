import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sodium_libs/sodium_libs.dart';

import '../../api/api_client.dart';
import '../../api/auth_api.dart';
import '../../api/transfers_api.dart';
import '../../api/users_api.dart';
import '../../core/config.dart';
import '../../crypto/envelope.dart';
import '../../crypto/file_crypto.dart';
import '../../crypto/keys.dart';
import '../../crypto/sealed_box.dart';
import '../../storage/secure_storage.dart';
import '../transfers/transfer_service.dart';
import '../verify_contact/verified_contacts_repo.dart';
import 'auth_repository.dart';

// --- infrastructure providers -------------------------------------------
// These are the seams tests override — a widget or repository test injects
// a fake by overriding one of these at the `ProviderScope` level.

final appConfigProvider = Provider<AppConfig>((_) => AppConfig.fromEnv());

final secureStorageProvider = Provider<SecureStore>((_) => SecureStore());

/// Sodium instance is expensive to initialise (native library load); build
/// once, share across the app.
final sodiumProvider = FutureProvider<Sodium>((_) => SodiumInit.init());

final keypairGeneratorProvider = FutureProvider<KeypairGenerator>((ref) async {
  final sodium = await ref.watch(sodiumProvider.future);
  return KeypairGenerator(sodium);
});

// The API client + auth repository have a chicken-and-egg dependency —
// each references the other — so we construct them together in a single
// provider and return everything the API + auth surface needs.
class _AuthWiring {
  const _AuthWiring({
    required this.authApi,
    required this.usersApi,
    required this.transfersApi,
    required this.repository,
  });
  final AuthApi authApi;
  final UsersApi usersApi;
  final TransfersApi transfersApi;
  final AuthRepository repository;
}

final _authWiringProvider = FutureProvider<_AuthWiring>((ref) async {
  final config = ref.watch(appConfigProvider);
  final storage = ref.watch(secureStorageProvider);
  final keys = await ref.watch(keypairGeneratorProvider.future);

  late final AuthRepository repo;
  final client = ApiClient(
    config: config,
    // Late-binding closure: the repo isn't built yet at construction.
    tokenSource: _LateBoundTokenSource(() => repo),
  );
  final authApi = AuthApi(client);
  final usersApi = UsersApi(client);
  final transfersApi = TransfersApi(client);
  repo = AuthRepository(api: authApi, storage: storage, keys: keys);

  ref.onDispose(client.close);
  return _AuthWiring(
    authApi: authApi,
    usersApi: usersApi,
    transfersApi: transfersApi,
    repository: repo,
  );
});

final authRepositoryProvider = FutureProvider<AuthRepository>((ref) async {
  final wiring = await ref.watch(_authWiringProvider.future);
  return wiring.repository;
});

final usersApiProvider = FutureProvider<UsersApi>((ref) async {
  final wiring = await ref.watch(_authWiringProvider.future);
  return wiring.usersApi;
});

final verifiedContactsRepoProvider = Provider<VerifiedContactsRepo>((ref) {
  return VerifiedContactsRepo(ref.watch(secureStorageProvider));
});

// --- M2 transfer surface ------------------------------------------------

final transfersApiProvider = FutureProvider<TransfersApi>((ref) async {
  final wiring = await ref.watch(_authWiringProvider.future);
  return wiring.transfersApi;
});

final sealedBoxProvider = FutureProvider<SealedBox>((ref) async {
  final sodium = await ref.watch(sodiumProvider.future);
  return SealedBox(sodium);
});

final fileCryptoProvider = FutureProvider<FileCrypto>((ref) async {
  final sodium = await ref.watch(sodiumProvider.future);
  return FileCrypto(sodium);
});

final envelopeProvider = FutureProvider<Envelope>((ref) async {
  final sodium = await ref.watch(sodiumProvider.future);
  return Envelope(sodium);
});

final transferServiceProvider = FutureProvider<TransferService>((ref) async {
  final transfers = await ref.watch(transfersApiProvider.future);
  final wiring = await ref.watch(_authWiringProvider.future);
  final sealedBox = await ref.watch(sealedBoxProvider.future);
  final fileCrypto = await ref.watch(fileCryptoProvider.future);
  final envelope = await ref.watch(envelopeProvider.future);
  final storage = ref.watch(secureStorageProvider);
  return TransferService(
    transfers: transfers,
    users: wiring.usersApi,
    sealedBox: sealedBox,
    fileCrypto: fileCrypto,
    envelope: envelope,
    storage: storage,
  );
});

// --- session state ------------------------------------------------------

/// `AsyncValue<AuthSession?>`:
///   - `AsyncLoading`  : initial keystore read in flight
///   - `AsyncData(null)`: signed out
///   - `AsyncData(sess)`: signed in
final authSessionProvider =
    AsyncNotifierProvider<AuthNotifier, AuthSession?>(AuthNotifier.new);

class AuthNotifier extends AsyncNotifier<AuthSession?> {
  @override
  Future<AuthSession?> build() async {
    final repo = await ref.watch(authRepositoryProvider.future);
    return repo.restoreSession();
  }

  Future<void> setSession(AuthSession session) async {
    state = AsyncData(session);
  }

  /// Persists + updates the in-memory session flag after a successful
  /// TOTP enrolment (or, later, disable). No-op when there's no session.
  Future<void> markMfaEnabled(bool value) async {
    final repo = await ref.read(authRepositoryProvider.future);
    await repo.setMfaEnabled(value);
    final current = state.value;
    if (current == null) return;
    state = AsyncData(current.copyWith(mfaEnabled: value));
  }

  Future<void> clear() async {
    final repo = await ref.read(authRepositoryProvider.future);
    await repo.signOut();
    state = const AsyncData(null);
  }
}

/// Bridges the ApiClient's [TokenSource] contract to whatever repo is
/// available at request time. Necessary because the repo depends on the
/// client and vice versa.
class _LateBoundTokenSource implements TokenSource {
  _LateBoundTokenSource(this._resolveRepo);
  final AuthRepository Function() _resolveRepo;

  @override
  Future<String?> readAccessToken() => _resolveRepo().readAccessToken();

  @override
  Future<String?> refreshAccessToken() => _resolveRepo().refreshAccessToken();
}
