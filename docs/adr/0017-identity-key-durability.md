# ADR-0017 — Identity key durability, and what we will not trade for it

**Status:** Accepted and implemented
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

## What was built

### Recovery key

128 bits from the CSPRNG, rendered in Crockford base32 (no I, L, O or U)
in groups of five: `XXXXX-XXXXX-XXXXX-XXXXX-XXXXXX`. Parsing accepts any
case, any separators, and maps the substitutions people actually make
back — this string exists to be copied by hand, and an alphabet
containing both `O` and `0` would manufacture support tickets.

The wrapping key is keyed BLAKE2b over a fixed domain-separation string.
Not a password KDF: the input is already 128 bits of uniform CSPRNG
output, so there is nothing for argon2 to stretch, and running one would
cost seconds on a phone for no measurable gain.

### Blob format

`"OSRK" | version(1) | nonce(24) | crypto_secretbox(payload)`

Magic and version so a wrong file fails with something that names the
problem, rather than as an authentication failure indistinguishable from
a mistyped key. The payload carries all four key halves plus the
fingerprint at the time of backup.

### Server

`key_backups`, keyed on `user_id`, one row per account, replaced
wholesale. Four endpoints under `/v1/users/me/key-backup`. The server
never parses the blob and stores no verifier the recovery key could be
tested against.

- **PUT and DELETE require the password.** Both are destructive. An
  attacker holding only a session gains nothing readable — the recovery
  key never reaches us — but could replace a backup with garbage,
  destroying the user's only route back from device loss, who would not
  find out until they needed it.
- **GET does not.** The blob is useless without the recovery key, and
  password-gating it would break the case this exists for: a fresh
  device where the point is that possession of the password is *not*
  what unlocks the key.
- **A separate `/status` endpoint** answers "does one exist" without
  shipping the ciphertext, because the app asks on every load to decide
  whether to prompt.
- **`downgrade` refuses** while any backup exists. These rows may be the
  only surviving copy of a user's identity key; dropping them silently
  would inflict exactly the loss this prevents, on the users who took
  the trouble to protect themselves.

### Rotation invalidates the backup

A backup taken before a key rotation still decrypts perfectly — and
yields the keypair that was just replaced. Restoring from it succeeds at
every visible step and then decrypts nothing.

So rotation deletes it, and the response carries
`key_backup_invalidated` so the client prompts for a fresh one rather
than leaving the account unprotected while appearing backed up.

### Restore checks against the published key

Before writing anything, the restored keypair is compared against the
public key the account currently publishes via `POST /v1/users/lookup` —
what a sender would seal to. The fingerprint is derived from the raw key
bytes returned, not from the server's own fingerprint field; trusting
its computed answer for a key/fingerprint binding would defeat the
check.

This catches the honest case — a rotation after the backup — and not a
lying server, which would produce a false mismatch. That is the trust
problem senders already have (whitepaper §5.2). What no server can do is
make a *wrong* restore succeed: the unwrap is authenticated by the
recovery key.

A lookup that fails does **not** block the restore. Someone recovering
is often doing so because things are broken, and stranding them to
preserve a warning would invert the priority.

### UI

- The recovery key is shown **once**, and leaving that screen is gated
  on an explicit acknowledgement — the value of the backup evaporates if
  the user taps past it by reflex.
- From the no-key state, **restore outranks replace**, and is the filled
  button. Restore brings the original key back so everything already
  sent opens; replacing abandons it. An earlier version offered only the
  destructive option, which invited someone to throw away recoverable
  mail because it was the only button on the screen.
- The prompt to create a backup appears only when the status is
  positively known to be absent. Nagging on an unknown — a network blip
  — teaches users to dismiss it, which costs more than the prompt saves.

## Consequences

- Web remains the weaker platform for receiving, and we say so in the
  product rather than implying parity.
- Eviction is now survivable rather than merely mitigated — but only for
  users who made a backup AND kept the recovery key. `persist()` remains
  best-effort, and someone who does neither is exactly where they were.
  The prompt is therefore doing real work, not decoration.
- We have taken on a support burden we did not have: users will lose
  recovery keys. That is a visible failure they had agency over, which
  is strictly better than the silent automatic loss it replaces, but it
  is not free.
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
