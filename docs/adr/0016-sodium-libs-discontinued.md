# ADR-0016 — `sodium_libs` is discontinued: stay on 3.x, migrate to `sodium` v4 when native assets are stable

Status: Accepted
Date: 2026-08-05

## Context

`sodium_libs` is the client's only cryptographic dependency. Every
primitive the product rests on comes through it: X25519 (`crypto_box_seal`
for `wrapped_key`), Ed25519 (envelope signatures), XChaCha20-Poly1305
(`crypto_secretstream` for file bodies), XSalsa20-Poly1305
(`crypto_secretbox` for `enc_header`), and `crypto_kdf` (suite-2 subkey
derivation). It is marked **discontinued** on pub.dev.

That fact was first raised during the crypto-core audit as an
unmaintained-dependency risk. **That framing was wrong**, and the
correction matters more than the original flag, so it is recorded here
rather than quietly dropped. The deprecation notice reads:

> Due to recent advancements in how dart handles native assets (more
> concretely the build hooks), this library is no longer required to use
> sodium in flutter applications.

`sodium_libs` was retired as **redundant**, not abandoned. It only ever
did one job — ship prebuilt libsodium binaries to Flutter targets — and
Dart build hooks now let the `sodium` package do that itself.

What was verified, rather than assumed:

- `sodium_libs` latest is **4.0.1**, and pub.dev names `sodium` as its
  replacement.
- `sodium` is at **4.0.4, published 14 hours before this ADR**, by the
  same verified publisher (skycoder42.de). The binding under our
  envelope has been actively maintained throughout.
- `sodium_libs` never contained crypto. It re-exports `sodium`, which is
  why `test/crypto/sodium_test_support.dart` can already load libsodium
  over FFI through `package:sodium/sodium.ffi.dart` while production
  goes through the plugin — same code, different loader.

So there is no window in which unmaintained cryptographic code is
shipping. The exposure is packaging, not cryptography.

## Decision

**Stay on `sodium_libs` 3.x for now. Migrate to `sodium` v4 when Dart
3.12+ is on the stable channel with native assets enabled by default.**

Two measurements drove this, both taken on the current toolchain
(Flutter 3.47.0-0.2.pre beta, Dart 3.13.0-282.3.beta):

1. **`sodium` 4.0.4 requires Dart SDK `^3.12.0`.** It resolves here —
   confirmed with a throwaway package — but our pubspec declares
   `sdk: ">=3.4.0 <4.0.0"`, so migrating raises the floor to 3.12 and
   drops every older SDK. We are currently on **beta**, not stable.
2. **`flutter config` reports `enable-native-assets: (Not set)`.** Build
   hooks are not on by default in this install, so a release build would
   need the flag explicitly. Enabling an off-by-default toolchain feature
   for the exact builds being submitted to App Store review and Play
   Console is a poor place to discover a packaging bug — and a
   `libsodium` that fails to build or bundle is not a degraded app, it is
   an app where nothing decrypts.

The migration itself is small, which is precisely why it does not need
doing under deadline pressure. The API is identical; only initialisation
changes:

```dart
await SodiumInit.init(loadLibsodium);  // v3
await SodiumInit.init();               // v4
```

`Sodium.runIsolated` also drops from three callback arguments to two. We
do not call it. Realistically this is one call site plus a pubspec swap.

## Consequences

- The client keeps shipping prebuilt binaries via `sodium_libs` 3.x. A
  discontinued package still resolves and still installs; pub.dev's
  marker is advisory.
- We accept receiving no further `sodium_libs` updates. Acceptable
  because it carries no crypto logic of its own — an upstream libsodium
  fix would reach us through `sodium`, and 3.x is still resolvable.
- The pubspec keeps `sodium` as a **dev** dependency (added so tests can
  load libsodium over FFI). That stays correct until the migration, at
  which point it becomes a normal dependency and `sodium_libs` is
  removed.
- **The migration should simplify the test harness.**
  `test/crypto/sodium_test_support.dart` exists only because
  `sodium_libs`' initialiser resolves the native library through the
  Flutter plugin, which throws `LateInitializationError` under
  `flutter test`. That single fact is what let 22 crypto tests report
  passing while executing no assertions. With v4's build hooks,
  `SodiumInit.init()` is expected to work directly in tests, and the FFI
  discovery harness, the `REQUIRE_LIBSODIUM` CI guard, and CI's
  `apt-get install libsodium23` step could all likely go away. Expected,
  not verified — confirm before deleting any of it, because the
  `REQUIRE_LIBSODIUM` guard is the only thing standing between us and a
  silently vacuous crypto suite.
- Do not raise the SDK floor for this alone. Fold it into the next
  deliberate SDK bump so the blast radius is one change, not two.

## Revisit when

Any of:

- Dart 3.12+ reaches the **stable** channel with native assets on by
  default (the expected trigger).
- `sodium` 3.x stops resolving, or an upstream libsodium advisory needs a
  version we cannot reach on 3.x.
- We bump the SDK floor for an unrelated reason — migrate in the same
  change.

Re-verify `enable-native-assets` and run a full release build for both
stores before submitting anything built on v4. The failure mode is total
(no decryption at all), so it wants a real build, not a passing test run.

## Alternatives considered

**Migrate now.** Rejected on timing, not merit. Apple compliance review
and the Play internal-testing track are both mid-flight; changing how the
crypto library is built and bundled while store submissions are in
progress trades a nonexistent risk for a real one.

**Move off libsodium entirely** — e.g. `package:cryptography`. Rejected,
and worth recording why so it is not revisited casually. That package has
no `crypto_secretstream` and no `crypto_box_seal`. Both are libsodium
constructions the wire format is built on: the OS4S container is chunked
secretstream framing, and `wrapped_key` is a sealed box. Replacing them
means redesigning the envelope **and** hand-rolling a chunked AEAD with
its own truncation and reordering defences — the class of code that
should never be written by hand. This would be a large, risky rewrite to
escape a dependency that is not actually at risk.

**Vendor libsodium and write our own FFI bindings.** Maximum control,
and the only option if `sodium` were genuinely abandoned. It is not.
Keep this in reserve for that scenario only.

## Open follow-ups

- Confirm, at migration time, whether `SodiumInit.init()` works under
  `flutter test`. If it does, retire `sodium_test_support.dart` and the
  CI libsodium install — but keep an equivalent of `REQUIRE_LIBSODIUM`
  unless initialisation failure is guaranteed to be loud.
- The link-mode receive path still has no test harness; app mode is
  covered by `test/features/transfers/receive_path_test.dart`. A suite
  migration touching `SodiumInit` is a reason to want that coverage
  first.
