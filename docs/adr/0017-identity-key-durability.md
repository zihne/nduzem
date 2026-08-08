# ADR-0017 — Identity key durability, and what we will not trade for it

**Status:** Accepted (direction); mitigations shipped, recovery mechanism not yet built
**Date:** 2026-08-08

## Context

The identity keypair is generated on the device at registration and
stored locally — Keychain on iOS, EncryptedSharedPreferences on Android,
and on web whatever `flutter_secure_storage_web` provides, which is
localStorage wrapped in AES-GCM with the wrapping key *also* in
localStorage.

`users.identity_pub` is written once at registration and **there is no
endpoint to update it.** So the private key has exactly one copy, in one
place, with no replacement path.

On native that is a reasonable design: the OS does not evict Keychain
entries on an inactivity timer. On web it is not, for three reasons of
increasing severity:

1. **Cross-browser.** Register in Chrome, sign in on Safari, and the
   fingerprint is absent and app-mode transfers cannot be decrypted.
   Recoverable — go back to Chrome — but surprising for a web app.
2. **Cleared storage.** Clearing site data, or registering in a private
   window, destroys the only copy. Not recoverable.
3. **Automatic eviction.** WebKit's storage policy deletes *all*
   script-writable storage — localStorage, IndexedDB, service worker
   registrations — after seven days of Safari use without a user
   interaction on the site. Not recoverable, and entirely silent.

Case 3 is the one that matters. A file-transfer tool is occasional-use
by nature, so "has not opened it in a week of browsing" is the ordinary
case rather than an edge case. The user then logs in successfully —
password auth is unaffected — and simply cannot decrypt anything ever
sent to them, while the server still advertises a public key whose
private half no longer exists anywhere. The account is alive and
receiving is dead, permanently.

## Decision

**Durability will not be bought by weakening the zero-knowledge
property.** Specifically, we reject escrow wrapped with the login
password, and we accept the recovery-key alternative.

### Rejected: password-wrapped escrow

The standard fix — derive a wrapping key from the user's password,
store the wrapped private key server-side — would solve every case
above. We are not doing it.

The server already stores an argon2id hash for authentication, so an
attacker holding the database can already grind the password. What
password escrow changes is not the feasibility of grinding but its
*payoff*: today cracking the password yields account access and
ciphertext, and still no plaintext, because the private key is on the
device. With password escrow it yields the identity private key, and
with it every app-mode transfer ever sealed to that key.

That makes this sentence in whitepaper §2.2 false:

> They do not gain the ability to decrypt in-flight or archived
> transfers.

At our parameters (t=3, m=64 MiB, p=4 — OWASP baseline) memory-hardness
caps a high-end GPU near 10³ guesses/sec, so a 100-GPU rig sits around
10⁵/sec. Against that, a ~30-bit password — which is roughly where
human-chosen passwords land, and our policy is `min_length=10` with no
composition rule — falls in about **90 minutes**. The median user's
escrow would not survive a database compromise.

The password would stop being the root of *authentication* and become
the root of the *cryptosystem*. That is the trade we are declining.

### Accepted: client-generated recovery key

Wrap the private key with a **128-bit key generated on the client**,
shown once, stored by the user. The server holds a blob it cannot
open — the same posture as `K_file`, which is a construction this
system already depends on everywhere else.

Three properties this must have, each easy to lose by accident:

- Generated client-side with a CSPRNG and **never transmitted**. Any
  endpoint that accepts it, even to "help", ends the property.
- Wrapped with an AEAD, so a malicious server cannot tamper the stored
  blob into something whose unwrap it can predict.
- **No server-side verifier** for the recovery key. At 128 bits this is
  arithmetically moot, but storing one invites reuse of the pattern
  somewhere it is not moot.

### Deferred: WebAuthn PRF

The PRF extension derives a stable secret from a passkey held in the
Secure Enclave / TPM / Android Keystore. Support is now broad (Safari
18+ via iCloud Keychain, Chrome, Firefox 139+). It would solve
durability *and* cross-browser at once, since passkeys sync, and it
needs no framework change — `dart:js_interop`, the same pattern as
`web_saver_web.dart`.

It is deferred rather than chosen because it is not free of trust:
synced passkeys put **Apple and Google in the chain**. iCloud Keychain
is end-to-end encrypted with an HSM-escrow recovery path tied to the
device passcode — a well-analysed design, not a backdoor — but it is a
third party that does not exist in our model today, and this product's
claim is that nobody else is in the path. Device-bound passkeys avoid
the third party but forfeit the sync that made PRF attractive.

So: recovery key is the *guarantee*, PRF is a later opt-in
*convenience*. When PRF ships, the recovery key must remain independent
of the passkey ecosystem, or a single Apple-account lockout takes both.

### Required regardless: key rotation

There is no rotation endpoint, so a user who loses their key is stuck
with a published public key nobody holds the private half of. Rotation
does not recover old files, but it turns a dead account into a working
one. This gap is **not web-only** — a lost or wiped phone is the same
position today.

## Shipped now

Cheap, zero-trade mitigations, ahead of the recovery mechanism:

- **`navigator.storage.persist()` at startup on web**
  (`lib/storage/persistent_storage.dart`). WebKit's eviction algorithm
  skips origins in persistent mode. Best-effort by construction: it is
  a *request* granted on engagement heuristics, and does nothing about
  cleared data, a second browser, or a lost device. Not awaited, never
  throws — it must not be able to delay or fail startup.
- **Honest messaging.** The old copy said "sign in on the device where
  you registered", which is right for the cross-browser case and
  actively misleading after an eviction, where no such device exists.
  Both the fingerprint card and the receive-path error now distinguish
  the two on web.
- **A warning before registering on web**, not after — someone choosing
  which browser to register in deserves to know the key lives there and
  cannot be restored. Covered by a widget test that asserts the opposite
  branch on native, since `kIsWeb` is a compile-time constant and the
  two branches are only reachable from `flutter test` and
  `flutter test --platform chrome` respectively.

## Consequences

- Web remains the weaker platform for receiving, and we say so in the
  product rather than implying parity.
- Until the recovery key ships, eviction is mitigated but not solved;
  `persist()` is best-effort and users can still clear storage.
- Whitepaper §2.2 stays true. §8.5 (browser delivery) already records
  the residual web-delivery assumption, which the recovery key does not
  remove and slightly raises the value of — a malicious page could
  capture the recovery key at generation time. Generating it in the
  mobile app is meaningfully stronger than in the browser, and the UX
  should say so rather than treat them as equivalent.

## References

- Whitepaper §2.2 (compromised server), §8.5 (browser delivery)
- [ADR-0011](0011-per-user-secure-storage.md) — per-user secure storage
- [Tracking Prevention in WebKit](https://webkit.org/tracking-prevention/)
- [Updates to Storage Policy — WebKit](https://webkit.org/blog/14403/updates-to-storage-policy/)
