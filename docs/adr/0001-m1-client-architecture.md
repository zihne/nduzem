# ADR-0001: M1 — client architecture (Riverpod + go_router + libsodium)

- **Status**: Accepted
- **Date**: 2026-07-01
- **Related**: build spec §2.3 (crypto design), §6 (auth + key handling),
  §12B.7 (client-side hardening), §13 (provability);
  server-side ADRs 0006 (email verification), 0007 (TOTP MFA)

## Context

Milestone 1 (identity foundation) opens the client work: register, verify
email, log in, optional TOTP, and land the signed-in user on a
placeholder home screen with their fingerprint visible. The server side of
M1 / M1.5 / M1.6 already ships against a stable API contract.

Design questions to lock down before writing code the rest of the app will
depend on:

1. **State management** — Riverpod, BLoC, or Provider.
2. **Routing** — go_router, auto_route, or raw Navigator 2.0.
3. **Crypto library** — a native FFI wrapper (`sodium_libs` / `sodium`),
   pure-Dart primitives, or a mixed choice per primitive.
4. **Secret storage** — how private keys and tokens land on disk.
5. **HTTP + token refresh** — `dio` vs. `http` + a hand-rolled interceptor.

## Decision

- **State: Riverpod without codegen.** `flutter_riverpod` gives async-first
  providers, no `BuildContext` coupling, and clean testability. Codegen
  (`riverpod_annotation`) will come when the provider surface grows past
  M1 — the M1 auth graph is small enough that hand-written providers stay
  readable.
- **Routing: `go_router`.** Declarative, deep-link-aware. Deep links come up
  twice in v1: the email-verification link (M1.5) and the link-mode
  receive URL (M5). Standardising on `go_router` from M1 avoids a router
  swap later.
- **Crypto: `sodium_libs` (libsodium via FFI).** X25519, Ed25519,
  `crypto_box_seal`, and `crypto_secretstream_xchacha20poly1305` are the
  primitives the spec targets. A pure-Dart implementation would duplicate
  well-audited C code for no gain. All crypto calls go through thin
  wrapper classes (`KeypairGenerator`, `SealedBox`, `SecretStream`,
  `Fingerprint`) so a future PQC suite (spec §2.6) has a single dispatch
  point.
- **Secret storage: `flutter_secure_storage`.** Keychain on iOS
  (`first_unlock` accessibility) and EncryptedSharedPreferences on Android
  (AES-256 GCM). All secret reads/writes go through a single `SecureStore`
  facade so an audit can trace every disk touch.
- **HTTP + token refresh: `package:http` + a hand-rolled `ApiClient`.**
  A ~150-line wrapper handles JSON, `Authorization: Bearer …`, and a
  single 401 → refresh → retry cycle via a small `TokenSource` seam. The
  `TokenSource` interface is implemented by the `AuthRepository`, which
  lets tests inject a fake without touching the network or the keystore.
  `dio` would bring an interceptor pipeline we don't need in v1.

**Folder layout:**

```
client/lib/
  main.dart              # ProviderScope + runApp
  app.dart               # MaterialApp.router
  router.dart            # go_router config + auth-gated redirect
  core/                  # config, Result<T,E>
  crypto/                # keys, fingerprint, suite, sealed_box (stub), secretstream (stub)
  storage/               # SecureStore facade
  api/                   # ApiClient, AuthApi
  features/
    auth/                # AuthRepository, providers, screens
    home/                # HomeScreen (M1 placeholder)
```

M2 will add `features/send/`, `features/inbox/`, etc. The `features/`
split keeps each milestone's changes local.

**Backend URL** comes from `--dart-define=OPAQUESHARE_API_BASE=…`. Default
`http://10.0.2.2:8000` matches the Android emulator loopback; iOS
simulator uses `http://localhost:8000`. Bare-metal builds must supply
the value at compile time.

## Consequences

- **A single seam per external concern.** Screens depend on
  `AuthRepository`; the repository depends on `AuthApi` + `SecureStore` +
  `KeypairGenerator`; each of those has one concrete implementation and a
  clear test double. Fifteen unit tests cover the crypto + repository
  layer without touching the network or the keystore.
- **Deep links work from day one.** `go_router` matches
  `/verify-email?user_id=…&token=…` regardless of whether it arrives via
  cold start, warm start, or in-app tap. Email verification and the
  future link-mode receive path share this machinery.
- **Auth-gated redirects live in ONE place.** The `redirect` callback in
  `router.dart` reads `authSessionProvider` and reroutes based on
  signed-in state. New screens don't have to defend themselves.
- **Riverpod's async-first providers cover the "session probe" case
  naturally.** `AsyncNotifier<AuthSession?>` returns `AsyncLoading` while
  we hit the keystore, `AsyncData(null)` if we're signed out, and
  `AsyncData(session)` when we're in. The router handles all three.
- **Sodium is discontinued as `sodium_libs`; we still use it.** The
  package is `sodium_libs 3.4.6+4` (deprecated in favour of the standalone
  `sodium 4.x` package). Migration is a non-trivial API change; deferred
  to a follow-up ADR before we ship a real build to the stores.
- **No `dio`, no code generation.** Two dependencies we don't have to
  audit for the reproducible-build story (§13.1). Every dependency in the
  pubspec is used directly.
- **The auth repository owns TWO seams** — the `ApiClient` token source
  and the session Notifier — via a `_LateBoundTokenSource` closure. The
  wiring lives in one place (`_authWiringProvider`) so the circular dep is
  contained.

## Alternatives considered

- **BLoC / Cubit.** Battle-tested but verbose for the M1 shape (register,
  login, verify, TOTP challenge — four repository methods and a session
  notifier). Riverpod's `AsyncNotifier` covers the same ground with less
  boilerplate.
- **Provider only.** Ships in Flutter core, so zero-dep. Fine for demos;
  the token-refresh + deep-link + async-init dance is where Riverpod's
  provider tree earns its keep.
- **`dio` for HTTP.** More features (interceptors, transformers, cancel
  tokens) than we need. `package:http` + 150 lines is enough for M1.
- **Auto-generated routes (`auto_route`).** Build_runner would slow the
  iteration loop for no observable gain at v1 scale.
- **Pure-Dart X25519 / Ed25519.** Adds attack surface (own implementation
  vs. libsodium's), slower, and no benefit for a client that must call
  `crypto_box_seal` and `secretstream` anyway.
- **Standalone `sodium 4.x`** (the successor to `sodium_libs`). Newer API
  shape; the `SodiumInit` bootstrapping surface changed. Migration is
  worth doing before store submission but not on the M1 branch — parking
  as a Consequence + follow-up.
- **`secure_storage_provider` / `hive_flutter` for tokens.** Non-hardware
  storage. Access token is a bearer credential — belongs in the same
  Keychain / EncryptedSharedPreferences bucket as the private keys.
- **Load the backend URL from a bundled config file.** `--dart-define` is
  a compile-time constant, which is what a reproducible-build pipeline
  wants; a file at runtime introduces environment drift.

## Open follow-ups

- **Migrate `sodium_libs` → `sodium`** before the first store submission.
  Track in a follow-up ADR once we've mapped the API differences.
- **Certificate pinning** on the API client for prod builds (spec §12B.2 /
  §12B.7). Not needed for M1's localhost dev flow; the ApiClient's `http`
  seam is the place to plug it in.
- **Cache the pending email** in a short-lived provider so the
  verify-email screen's "resend" path doesn't require signing in again.
- **Widget tests** for the register + login screens (mock repository at
  the `ProviderScope` level). Non-blocking for M1 but small.
- **Reproducible-build manifest** — pin the Flutter SDK version and every
  transitive lockfile hash in `provability/reproducible-build/` for the
  §13.1 verification story. Lands with M13 client hardening.
