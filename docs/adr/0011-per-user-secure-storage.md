# ADR-0011 — Per-user secure_storage for identity keypairs

Status: Accepted
Date: 2026-07-21

## Context

The M1 client persisted identity + signing keypairs under a fixed set of
constant slot names in `flutter_secure_storage`:

- `auth.identity_private_b64`
- `auth.identity_public_b64`
- `auth.signing_private_b64`
- `auth.signing_public_b64`

Fine for one user per device. The moment a second account was registered
on the same device — a common testing pattern, and an eventual real-user
one for shared family devices — the constants collide: the second
`register()` overwrites the first user's keypair. Whichever account
signed in last owns the slots. Everyone else on the device now has:

- The wrong `signing_priv` on hand — every `send()` produces a
  signature that fails server-side verification against the account's
  stored `signing_pub`.
- The wrong `identity_priv` — sealed `K_file` blobs targeted at the
  original account's `identity_pub` can no longer be unsealed. Received
  transfers surface as "libsodium failed to open."

This was discovered during Play Console review setup, where the tester
needed distinct sender and recipient accounts. Two accounts on one
device meant one account was always broken.

## Decision

Namespace keypair slots by the user id they belong to. Session-scoped
state (tokens, email, handle, MFA flag, fingerprint) stays single-slot —
only keypair material is per-user.

**Slot naming.** The old constants become private and are treated as
legacy-migration sources only. Public helpers on `SecureStore` mint the
scoped slot name for a given user id:

```dart
static String identityPrivateKeyFor(String userId)
    => 'auth.identity_private_b64.$userId';
static String identityPublicKeyFor(String userId)
    => 'auth.identity_public_b64.$userId';
static String signingPrivateKeyFor(String userId)
    => 'auth.signing_private_b64.$userId';
static String signingPublicKeyFor(String userId)
    => 'auth.signing_public_b64.$userId';
```

`AuthRepository._persistKeypair` takes `{userId, pair}` and writes into
the scoped slots. `TransferService.send` and `receive` read
`kUserId` first, then look the current session's keypair up via
`signingPrivateKeyFor(activeUserId)` etc.

**One-time migration.** `SecureStore.migrateLegacyKeypairIfNeeded()`
runs from `AuthRepository.restoreSession()` at every app cold-start.
Idempotent:

- If the first legacy slot is absent, no-op (already scoped, or fresh
  install).
- If legacy slots are present AND `kUserId` is set, copy the quartet
  into scoped slots for that user, then delete the legacy slots. A
  partial legacy set (three of four) is left alone — probably a botched
  prior state; better to leave than to write scoped slots that can't
  decrypt anything.
- If legacy slots are present but `kUserId` is not, log and leave.
  Migration fires on the next successful login instead.

**Failure surfaces.** `send` / `receive` still throw when the required
scoped key is missing — for example, an account that was registered on
device A and only ever *signed in* on device B has no local keypair.
The error messages are explicit: "This device doesn't have the signing
key for this account. The account was likely created on another device
… Register a fresh account on this device to send from here, or sign in
from the device where this account was originally registered." Users
learn to distinguish "wrong device" from "genuinely broken."

**Purge semantics.** `purgeSession` (sign-out) is unchanged — clears
tokens and the MFA flag, preserves everything else including the
current user's scoped keypair. `purgeAll` (device wipe) deletes only
the *currently active* user's scoped slots plus the legacy slots for
cleanup; other users' scoped slots are preserved intentionally. A new
`forgetUserKeypair(userId)` targets a specific user's slots for the
future "forget this account on this device" settings affordance.

## Consequences

- Two accounts registered on the same device coexist cleanly. A
  sign-out + sign-in-as-the-other-account seamlessly picks up the
  correct local keys and can decrypt past sealed transfers.
- Upgrade path is transparent: existing users with legacy slots get
  migrated on first cold-start of the new build; no manual step, no
  re-register required.
- Storage cost is proportional to the number of accounts hosted on a
  device — negligible even for a family device with a handful of
  accounts (~250 bytes per keypair).
- The "sign in on a fresh device" case remains a genuine dead end for
  app-mode receive today (zero-knowledge design: private keys don't
  sync). Users see an explicit error rather than a silent libsodium
  failure. Documented in the ADR-0007 open follow-ups.

## Alternatives considered

- **Single-slot with account-swap wipe.** Keep the constants; wipe them
  on every sign-out. Rejected: destroys the "same-account re-login can
  still decrypt K_files" invariant, and doesn't solve the concurrent
  same-device case at all.
- **Sync private keys via the server.** Simplest UX; unacceptable for a
  zero-knowledge product. The server cannot see private keys, ever.
- **Per-user encrypted vault, one blob.** A single JSON blob keyed by
  `userId`, decrypted with a hardware-key-wrapped DEK. Overkill —
  `flutter_secure_storage` already provides per-key hardware-backed
  encryption; layering our own vault buys nothing and adds crypto we'd
  have to justify.

## Open follow-ups

- Settings screen "forget this account on this device" wired to
  `SecureStore.forgetUserKeypair(userId)`.
- Legacy-slot sweeper: after the migration has been out for two
  release cycles, add a one-shot delete of any residual `auth.*_b64`
  legacy slots that couldn't be migrated (partial state, no `kUserId`).
  Not urgent — those slots are harmless dead storage.
- Per-user local persistence for transfer history + verified contacts.
  Same class of bleed as the keypair issue. Tracked separately in
  ADR-0012.
