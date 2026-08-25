import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sodium_libs/sodium_libs.dart';

import '../../api/api_client.dart';
import '../../api/auth_api.dart';
import '../../api/billing_api.dart';
import '../../api/links_api.dart';
import '../../api/transfers_api.dart';
import '../../api/users_api.dart';
import '../../core/config.dart';
import '../../crypto/envelope.dart';
import '../../crypto/file_crypto.dart';
import '../../crypto/keys.dart';
import '../../crypto/sealed_box.dart';
import '../../native/saf_saver.dart';
import '../../storage/secure_storage.dart';
import '../billing/iap_purchase_service.dart';
import '../history/transfer_history_provider.dart';
import '../transfers/recipient_cache.dart';
import '../transfers/transfer_service.dart';
import '../verify_contact/verified_contacts_repo.dart';
import 'auth_repository.dart';

// --- infrastructure providers -------------------------------------------
// These are the seams tests override — a widget or repository test injects
// a fake by overriding one of these at the `ProviderScope` level.

final appConfigProvider = Provider<AppConfig>((_) => AppConfig.fromEnv());

final secureStorageProvider = Provider<SecureStore>((_) => SecureStore());

/// Native SAF stream-save (ADR-0008). Android: real method-channel
/// impl; other platforms: stub that declines so the receive screen
/// routes to the ADR-0006 fallback.
final safSaverProvider = Provider<SafSaver>((_) => SafSaver.platformDefault());

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
    required this.linksApi,
    required this.billingApi,
    required this.repository,
  });
  final AuthApi authApi;
  final UsersApi usersApi;
  final TransfersApi transfersApi;
  final LinksApi linksApi;
  final BillingApi billingApi;
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
  final linksApi = LinksApi(client);
  final billingApi = BillingApi(client);
  repo = AuthRepository(
    api: authApi,
    usersApi: usersApi,
    storage: storage,
    keys: keys,
  );

  ref.onDispose(client.close);
  return _AuthWiring(
    authApi: authApi,
    usersApi: usersApi,
    transfersApi: transfersApi,
    linksApi: linksApi,
    billingApi: billingApi,
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

final billingApiProvider = FutureProvider<BillingApi>((ref) async {
  final wiring = await ref.watch(_authWiringProvider.future);
  return wiring.billingApi;
});

/// M3.3 Play Billing state machine. Kept alive across paywall
/// mount/dismount so an in-flight purchase doesn't lose its
/// acknowledgement if the user backs out of the screen (see ADR-0002).
/// Region is hard-coded to `US` for v1; the M9.x settings surface will
/// wire in an operator override.
final iapPurchaseServiceProvider =
    FutureProvider<IapPurchaseService>((ref) async {
  final billingApi = await ref.watch(billingApiProvider.future);
  final service = IapPurchaseService(billingApi: billingApi, region: 'US');
  await service.initialize();
  ref.onDispose(service.dispose);
  return service;
});

/// Rebuilds when the auth session's `userId` changes, so a hot
/// account swap resolves to the newly-signed-in user's scoped
/// verification list (ADR-0012). When there's no session the repo
/// short-circuits every call to null/no-op.
final verifiedContactsRepoProvider = Provider<VerifiedContactsRepo>((ref) {
  final session = ref.watch(authSessionProvider).valueOrNull;
  return VerifiedContactsRepo(
    ref.watch(secureStorageProvider),
    localUserId: session?.userId,
  );
});

/// Resolved-recipient cache (ADR-0039), scoped to the signed-in user for
/// the same reason the verification list is: two accounts on one device
/// must not see each other's correspondents. Inert when signed out.
final recipientCacheProvider = Provider<RecipientCache>((ref) {
  final session = ref.watch(authSessionProvider).valueOrNull;
  return RecipientCache(
    ref.watch(secureStorageProvider),
    localUserId: session?.userId,
  );
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

final linksApiProvider = FutureProvider<LinksApi>((ref) async {
  final wiring = await ref.watch(_authWiringProvider.future);
  return wiring.linksApi;
});

final transferServiceProvider = FutureProvider<TransferService>((ref) async {
  final transfers = await ref.watch(transfersApiProvider.future);
  final wiring = await ref.watch(_authWiringProvider.future);
  final sealedBox = await ref.watch(sealedBoxProvider.future);
  final fileCrypto = await ref.watch(fileCryptoProvider.future);
  final envelope = await ref.watch(envelopeProvider.future);
  final storage = ref.watch(secureStorageProvider);
  final sodium = await ref.watch(sodiumProvider.future);
  final service = TransferService(
    transfers: transfers,
    links: wiring.linksApi,
    users: wiring.usersApi,
    sealedBox: sealedBox,
    fileCrypto: fileCrypto,
    envelope: envelope,
    storage: storage,
    sodium: sodium,
  );
  // The service creates its own `http.Client` and holds it open for reuse
  // across parts and requests. Close it when the provider is disposed —
  // otherwise the connection pool outlives the service that owns it.
  ref.onDispose(service.dispose);
  return service;
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

  /// Fetch `/v1/users/me` and reconcile the local session (ADR-0032).
  /// Called by the register + login flows right after they set the
  /// initial session. Failures here are swallowed on purpose — the
  /// server is authoritative for what `/me` returns, but a network hiccup
  /// on the follow-up call should not tear down a session the caller has
  /// already established. The next successful call refreshes the state.
  Future<void> refreshMe() async {
    final current = state.value;
    if (current == null) return;
    try {
      final repo = await ref.read(authRepositoryProvider.future);
      final updated = await repo.refreshMe(current);
      state = AsyncData(updated);
    } on Object {
      // Intentionally silent — a failed /me refresh is a soft failure.
    }
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
    // ORDER MATTERS. Both stores are scoped by the local user id, which
    // comes from the session — so they must be cleared while the session
    // still exists. After `signOut()` the providers resolve to a null
    // user and every call short-circuits, leaving the data behind.
    //
    // What goes and what stays (ADR-0039): transfer history is cleared,
    // verified contacts survive. History is the revealing record — "I
    // sent contract.pdf to alice@example.com on Tuesday" — and cheap to
    // lose. A verification is the opposite: barely sensitive, and
    // expensive to recreate, because it means comparing a safety number
    // out of band. Discarding those on every sign-out is how you teach
    // people to stop verifying.
    await ref.read(recipientCacheProvider).clear();
    await ref.read(transferHistoryProvider.notifier).clearAll();

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


/// Whether this account has an encrypted key backup.
///
/// Watched by the home screen so it can prompt when there is none. A
/// separate provider rather than part of the session because it is a
/// server fact that changes independently — creating a backup, or a key
/// rotation invalidating one — and because a failure to fetch it must
/// not take the whole session down with it.
final keyBackupStatusProvider = FutureProvider<KeyBackupStatus?>((ref) async {
  final session = await ref.watch(authSessionProvider.future);
  if (session == null) return null;
  try {
    final repo = await ref.watch(authRepositoryProvider.future);
    return await repo.keyBackupStatus();
  } on Object {
    // Unknown, not "absent". Nagging someone to make a backup they
    // already have — because the network blipped — trains them to
    // dismiss the prompt, which is worse than not showing it.
    return null;
  }
});
