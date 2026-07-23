# ADR-0012 — Per-user local persistence for transfer history + verified contacts

Status: Accepted
Date: 2026-07-23

## Context

ADR-0011 scoped the identity + signing keypair slots in
`flutter_secure_storage` by user id so two accounts on the same device
can coexist. A subsequent test with a real device swap surfaced two
more local stores that ADR-0011 did NOT cover, and that bleed just as
badly across accounts:

- **Transfer history** (ADR-0007) — one file at
  `<app-docs>/transfer_history.json`, unscoped. Alice sends a
  file, signs out; Bob signs in on the same device; Bob's history
  screen shows Alice's transfers, with counterparty names, filenames,
  and timestamps. Privacy leak by any reasonable reading.
- **Verified contacts** (ADR- adjacent to M2.5 fingerprint OOB) —
  `flutter_secure_storage` keys of shape `vc.<counterpartyId>` holding
  the fingerprint canonical string and the verification timestamp.
  Scoped by *counterparty*, but not by *local user*. Alice verifies
  Bob out-of-band; Bob's fingerprint is stored under `vc.<bob-id>`.
  Charlie signs in on the same device; `verified_contacts_repo.read(bob-id)`
  returns Alice's verification. Charlie now sees Bob as "verified" on
  the send screen without ever verifying him. Worse than the history
  bleed: a *safety* signal (the shield tick that says "this is really
  Bob") comes from a verification that isn't Charlie's.

Both are the same class of bug as the keypair issue in ADR-0011: local
persistence keyed by something other than the local user's id, in a
world where "local user" can change between reads and writes.

## Decision

Extend ADR-0011's per-user invariant to all persistent local data
stores. Anything on disk that's specific to a signed-in user gets
namespaced by that user's id. Only two stores are in scope right now —
transfer history and verified contacts — but the rule holds for future
stores: **if you're writing something to local storage that depends on
who's signed in, scope it by user id, or you're building a bleed.**

**Transfer history.** The file becomes
`<app-docs>/transfer_history.<userId>.json`. The repository's
constructor takes a nullable `userId`. When `userId` is null (no
session), `readAll()` returns empty and mutations no-op — this matches
reality, since the history screen is only reachable when signed in
anyway. The provider watches the auth session and rebuilds the repo
with the current user's id, so a hot account swap in a testing session
shows the right file immediately.

**Verified contacts.** Keys become `vc.<localUserId>.<counterpartyId>`.
The repo's constructor takes a nullable `localUserId`; null
short-circuits to no-record / no-op. Provider wires from the auth
session, same pattern as history.

**One-time migrations.** Both stores run migrations lazily on first
use after the upgrade:

- History: if the scoped file `transfer_history.<userId>.json` doesn't
  exist AND the legacy `transfer_history.json` does AND `userId` is
  non-null, rename the legacy file to the scoped path. First read
  returns the migrated data.
- Verified contacts: enumerate all secure_storage keys, find any
  matching the legacy `vc.<X>` shape (prefix `vc.` and no second `.`),
  rewrite as `vc.<localUserId>.<X>`, delete the original. Attribute
  the legacy verifications to the currently signed-in user — under
  the single-slot secure_storage model those were the only user with
  a coherent local keypair, so they're the user those verifications
  belonged to in practice.

Both migrations are idempotent — a second run finds no legacy state
and is a no-op.

**Purge semantics.** No changes to `AuthRepository.signOut()`. The
provider layer already reads the current `kUserId`, so signing out then
signing in as user B swaps the visible history and verified contacts
without either repo touching data belonging to user A. Preserves
ADR-0011's "session logout vs device wipe" distinction: the user is
free to sign back in as A later and see their preserved state.

## Consequences

- No cross-account bleed for transfer history or verified contacts. A
  freshly signed-in user with no prior activity on this device sees an
  empty history screen and no "verified" ticks.
- Same-user sign-out / sign-in cycle preserves both history and
  verifications for that user — matches ADR-0011.
- Storage cost is proportional to accounts hosted on the device. Each
  history file caps at 200 entries (~100 KB); each verified-contact
  key is ~100 bytes. Negligible.
- Upgrade path: existing users see their history and verifications
  attributed to their current session on first cold-start of the new
  build. Silent; no re-verification required.
- Providers now depend on `authSessionProvider`. Anywhere history or
  verified contacts are read outside of a signed-in context (nothing
  currently), the calls become no-ops rather than throwing. Caller
  code doesn't need to gate; the repos handle the null case.

## Alternatives considered

- **Clear-on-sign-out.** `signOut()` calls `TransferHistoryRepository
  .clearAll()` and equivalent for verified contacts. Rejected: breaks
  the "sign-out is session-level, not device-wipe" distinction from
  ADR-0011; a same-account re-login loses history and verifications
  it should still own. Also doesn't help the concurrent-testing case
  where a user swaps accounts mid-session without signing out.
- **Filter at read time.** Keep a single unscoped file; embed
  `ownerUserId` on every entry; filter reads by the current user id.
  Rejected: still leaks metadata at the filesystem level (Bob can see
  Alice's history file on a rooted device), and the schema-migration
  cost of retrofitting `ownerUserId` on the existing entry shape
  isn't smaller than the file-scoping cost.
- **Full-blown per-user directory.** `<app-docs>/users/<userId>/…` as
  a scoping root for every future local artefact. Attractive
  long-term; overkill for two stores today. Revisit if a third store
  needs the same treatment — the abstraction is one refactor away.

## Open follow-ups

- Same "forget this account on this device" affordance from ADR-0011
  should also delete the scoped history file and any
  `vc.<localUserId>.*` keys. Filed under settings-screen work.
- If a future store lands (analytics opt-in state, per-user preferences,
  offline queue for outbound transfers), it inherits this rule.
  ADR-0012 is the anchor to point at.
