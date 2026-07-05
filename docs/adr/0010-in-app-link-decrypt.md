# ADR-0010: In-app link-mode receive (deep-link `/r/<id>#<K>`)

- **Status**: Accepted
- **Date**: 2026-07-04
- **Related**: [ADR-0005](0005-m5-link-mode-sender.md) (client-side
  link sender — flagged this deep-link handler as a follow-up),
  [ADR-0006](0006-m4-streaming-receive.md) (streaming receive pipeline
  we reuse), server ADR-0035 (web decrypt page — the JS behaviour we
  mirror in-app), server ADR-0014 (link-mode backend)

## Context

Link-mode shares today land the recipient on `<origin>/r/<id>#<K>` in
the browser, where the JS decrypt page (server ADR-0035) does the
work: `GET /v1/links/<id>` for info, `POST /download` with the
optional password, fetches the presigned URL, streams the ciphertext
into memory, decrypts with libsodium.js, offers `<a download>`, and
POSTs `/ack`.

That works, but has real drawbacks for recipients who happen to have
the app installed:

- Whole-ciphertext-in-memory caps browser decryption at 1–2 GB per
  tab — huge sends fail silently or crash the tab.
- The web save uses a synthetic `<a download>`; users can't pick a
  save destination on Android and lose control of where the file
  lands.
- There's no local history record — the recipient can't answer "who
  sent me that file last Tuesday" a week later.
- The web page has to reload libsodium.js (~740 KB) on every visit,
  which is wasteful for repeat users.

The native app already has all the pieces to do this better: streaming
download + decrypt + save (ADR-0006), native SAF stream-save
(ADR-0008), transfer history (ADR-0007). We just need to route
`/r/<id>#<K>` into the app when installed and mirror the JS
algorithm using the existing pipeline.

Open decisions:

1. **How does the URL fragment reach the app?** Deep-link via
   Android universal links, custom scheme, or both?
2. **Auth boundary** — link mode is unauthenticated. Where does the
   router allow that through without breaking the "unauth → /login"
   redirect?
3. **Sender identity + signature verification** — the server never
   surfaces the sender's pubkey for link-mode transfers, so the JS
   page skips signature verify. Do we mirror that or attempt a
   verification of some kind?
4. **Password UX** — a subset of links have optional passwords.
5. **iOS** — Universal Links + associated domains file. Do we
   implement both platforms now?

## Decision

### Android universal-link intent filter, `/r/*` on the operator's host

Add an `<intent-filter>` with `android:autoVerify="true"` claiming
`https://<host>/r/*`. The host lives in the manifest, and the
operator publishes a matching `.well-known/assetlinks.json` on that
host with the app's SHA-256 signing fingerprint — that's how Android
"knows" the app should intercept the URL instead of falling through
to the browser.

For v1 the manifest ships `opaqueshare.com` as a placeholder, with a
comment explaining the operator must swap it for their actual host
and deploy `assetlinks.json`. Universal Links fail open — tapping
the URL when the app isn't verified for that host just opens the
browser, which lands on the JS page as before. Nothing breaks; the
app just doesn't intercept.

**No custom scheme** (`opaqueshare://...`) — custom schemes work
but split the "share this URL" surface (recipient without the app
would see a broken link if the sender used the custom-scheme URL).
The universal-link approach gives us one URL that works whether the
recipient has the app or not.

### `/r/:transferId` route + auth-redirect allowlist

Add `GoRoute(path: '/r/:transferId', builder: … LinkReceiveScreen …)`.
The path parameter carries the transfer id; the URL fragment
(`state.uri.fragment`, base64url K_file) rides through go_router's
own uri parsing.

The router's redirect middleware adds `/r/` to the pre-auth
allowlist — link-mode receive is unauthenticated by design (the
transfer id + fragment ARE the credentials), and signed-out users
must be able to open a link they were sent.

### Skip sender-signature verification, keep the ciphertext hash check

Link mode has no on-platform sender identity — the server never
surfaces `sender_signing_pub` on `/v1/links/*` responses (server
ADR-0031 makes this deliberate: the sender exists in the
authenticated app-mode surface only). Following the JS page's
approach, the in-app link receive skips the signature check and
notes signature status as `false` on the resulting
`DecryptedTransfer`.

The **ciphertext SHA-256 check** (server-declared `blob_sha256` vs.
locally computed hash) stays — it's cheap, catches transport
corruption, and doesn't need any sender identity. Same guarantee the
web page provides.

### `TransferService.receiveLinkMode(...)` — a distinct method

Rather than fold link-mode into the existing `receive()`, add
`receiveLinkMode({transferId, fileKey, password})`. The two flows
share enough that a full duplicate would drift — but they differ in:

- **Endpoint** (`/v1/links/*` vs. `/v1/transfers/*`), no bearer
  token on the wire.
- **Key material** — `fileKey` arrives from the URL fragment, NOT
  from `wrapped_key` unsealing.
- **Signature verify** — skipped, per above.

Sharing at the *helper* level (`_streamDownloadWithHash`,
`_fileCrypto.decryptFileToTempFile`) keeps the pipeline consistent;
sharing the outer `receive()` method would create a mode flag that
fuzzes the auth boundary. Same reasoning the server uses to keep
`/v1/links/` and `/v1/transfers/` as separate routers.

### `LinkReceiveScreen` — password gate + download + save

New screen at `/r/:transferId`. Renders in stages:

1. **Loading `/v1/links/<id>` info.** Handles: `exists=false` (404
   look-alike), `expired=true`, `consumed=true`,
   `password_required=true`. Each state is a distinct panel so the
   recipient understands why the download can't proceed.
2. **Password prompt** when required. Submit re-tries the download
   call.
3. **Download + decrypt** — same two-phase progress bar
   (`downloading`, `decrypting`) the authed receive uses.
4. **Save** — via `SafSaver` (ADR-0008) on Android; iOS falls back
   to the app-documents path (ADR-0006 pattern).
5. **Ack** — auto-fires after successful save.
6. **History** — logs a `ReceivedHistoryEntry` (ADR-0007) with
   `senderHandle = null`, `senderIdShort = null`,
   `signatureVerified = false`.

### iOS deferred to a follow-up

Universal Links on iOS require an `apple-app-site-association` file
served from the host root over HTTPS + an entitlement in the app's
plist. The pattern mirrors Android but the plumbing is entirely
different, and the owner is on Android. Deferred until iOS
distribution matters.

The `LinkReceiveScreen` still works on iOS via manual navigation
(e.g., pasting the URL, or once we add an "open a link" surface on
the home screen). The deep-link *interception* is what's iOS-
deferred, not the receive logic.

### `LinksApi` — thin API client mirroring the endpoint shape

New `LinksApi(ApiClient)` with:

- `info(transferId) -> LinkInfo` — `GET /v1/links/<id>`, no auth.
- `download(transferId, {password}) -> LinkDownload` — `POST
  /v1/links/<id>/download`, no auth, optional password body.
- `ack(transferId) -> String` — `POST /v1/links/<id>/ack`.

All three run through the existing `ApiClient` unauthed path.
Server rate-limits per-IP (ADR-0014 + M8.1) — that stays the
brute-force floor for the password field.

## Consequences

- **Users with the app installed get streaming + SAF save + local
  history for link receives.** No 1–2 GB browser cap; multi-GB link
  transfers become a first-class experience.
- **Users without the app keep the web page.** Same URL, same UX.
  The universal-link mechanism means the OS routes the intent to
  whichever handler is available.
- **`AndroidManifest.xml` gets an operator-owned `<data
  android:host>`.** Anyone forking this repo has to change the host
  and deploy `assetlinks.json`, but that's already the state of
  affairs for any deep-link-capable app.
- **`TransferService` grows one method + one new API surface
  (`LinksApi`).** Small.
- **The signature-verified badge stays visible in history** for
  link receives — set to false. Users learn to interpret that as
  "no on-platform sender to verify against," not "verification
  failed."
- **The router's auth-redirect logic explicitly allowlists
  `/r/*`.** This is the ONE unauthenticated app-mode route besides
  the existing pre-auth surfaces. Reviewers should keep this in mind
  when touching the middleware.

## Alternatives considered

- **Custom scheme** (`opaqueshare://r/<id>#<K>`). No domain
  verification needed, works out of the box for testing. Rejected
  because the sender's URL then has to either (a) commit to the
  custom scheme and break for recipients without the app, or (b)
  ship two links, which is silly.
- **Fold link mode into `receive()` with a `SendMode`-style flag.**
  Would share more code but blur the auth boundary — the same
  method would need to condition on "am I authenticated?" and
  "which endpoint do I hit?" We've kept the server strict about
  this separation (ADR-0014); the client should mirror it.
- **Do signature verify against the transfer creator anyway.** No —
  server ADR-0031 explicitly withholds sender pubkeys on link-mode
  endpoints. The transfer is designed to be recipient-agnostic; a
  signature over `blob_sha256` doesn't help without a signer
  identity, which link mode doesn't publish.
- **Ship iOS Universal Links in this branch.** Different plumbing,
  no test surface until iOS distribution is set up. Cheaper as a
  follow-up.
- **Prompt for a save destination BEFORE download.** SAF picker
  before the ciphertext is downloaded could avoid the temp-file
  step. But then the user waits N minutes to be told the wrong
  file was picked, or the size warning comes too late. Same
  pattern as ADR-0006: download → decrypt → save, so the user
  sees size + filename before they commit.

## Open follow-ups

- **iOS Universal Links** — associated-domains entitlement +
  `apple-app-site-association`. Same design, different plumbing.
- **"Open a link" surface** on the home screen — for iOS
  (pre-deep-link support) and for users who want to paste a URL
  from an external source. Small addition.
- **Batch link decrypt** — if a sender ships multiple links, a
  paste-many surface. Speculative.
- **Sender-verified link mode** — an optional variant where the
  sender signs the URL with an out-of-band key, so a recipient
  can verify authenticity even without an on-platform sender
  identity. Deep design, deferred.
- **Rate-limit UX** — link-mode is rate-limited per IP; a 429
  today surfaces as a generic error. Consider a specific "too many
  attempts, try again later" panel.
