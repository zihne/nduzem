# ADR-0005: M5 — client-side link-mode sender

- **Status**: Accepted
- **Date**: 2026-07-03
- **Related**: server ADR-0014 (M5 link-mode backend),
  server ADR-0035 (M5 web decrypt page),
  [ADR-0003](0003-m4-client-multipart.md) (streaming send),
  [ADR-0004](0004-m4-streaming-send.md) (from-disk streaming)

## Context

M5 introduces link-mode transfers: the sender produces a shareable
URL of the form `<origin>/r/<transfer_id>#<K_file>`, and any
recipient with that URL can decrypt the file in a browser (server
ADR-0035) without an account. The `K_file` fragment stays
client-side; the server sees only `<origin>/r/<transfer_id>`.

Server-side link mode is shipped. This branch adds the sender flow to
the Flutter app:

- A mode toggle on the send screen ("Send to a user" / "Share as
  link").
- Link mode: skip the recipient lookup + fingerprint check (no
  recipient), optional password, submit with `mode: "link"` and no
  `wrapped_key`.
- Show the resulting URL to the user with a copy button.

Design questions:

1. **How do we model the two modes internally?** Add a `SendMode`
   enum on `TransferService.send` vs two entirely separate methods?
2. **Base-URL discovery for the share link.** The API base URL is
   already in `AppConfig`; the web decrypt page is served from the
   same origin. Reuse or add another config?
3. **What UX affordances are worth building for v1?** Password only?
   Also max_downloads? Also custom expiry?
4. **Where does the URL land in the completion flow?** Reuse the
   `_SendCompleteDialog` from app-mode with a different body, or ship
   a separate dialog?

## Decision

### Mode enum on `TransferService.send`

`SendMode { app, link }` added to `transfer_service.dart`, passed as
a required `mode:` parameter. Rationale over separate methods:

- The pre-encrypt steps (K_file generation, streaming encryption
  to a temp file, blob_sha256 computation, enc_header build) are
  100% shared between the modes.
- Post-encrypt divergence is contained: link mode skips
  `SealedBox.seal(K_file, recipient_identity_pub)`, sends
  `mode: "link"` + optional `link_password`, and returns the
  K_file as-is to the caller so it can be embedded in the URL
  fragment.
- Two methods would duplicate ~300 lines of streaming/multipart
  logic. A single method with a small branch is cheaper to
  maintain.

### Base URL: reuse `AppConfig.apiBaseUrl`

The server hosts `/r/<id>` on the same origin as `/v1/*` (per
ADR-0035, `app.mount("/r", ...)` sits alongside the API routes).
The share URL is:

```
${apiBaseUrl}/r/<transfer_id>#<K_file_base64url>
```

No new config knob needed. If we ever separate the public web
origin from the API origin (e.g. `api.opaqueshare.com` vs
`link.opaqueshare.com`), we add a `linkBaseUrl` setting and the
share URL builder switches over — trivial follow-up.

**Base64url without padding** for the fragment: 32 bytes of key →
43 characters, no `=` padding. Uses Dart's `base64Url.encode` +
stripping trailing `=`. The web decrypt page pads back before
`atob` on the JS side (matched implementation).

### v1 UX scope: mode toggle + optional password + max_downloads

Ships:

- **Segmented mode toggle** at the top of the send screen. Default
  is "Send to a user" so existing behaviour is unchanged for users
  who don't discover link mode.
- **Optional password field** on link mode. Min 4 chars per the
  server's Pydantic validator. Empty → no password.
- **Max downloads dropdown** (default 1, options 1/3/10). Server
  allows 1-10 per the `max_downloads` field's Pydantic constraint.
- **Result dialog** unique to link mode: title *"Link created"*,
  the URL as `SelectableText` in a monospace box, big "Copy link"
  button that calls `Clipboard.setData`. Barrier-dismissible false,
  matching the app-mode dialog we shipped.

Deliberately skipped for v1:

- **Custom expiry**. Server default is 7 days (spec §8). A UI knob
  adds friction without evidence anyone needs less/more today.
- **`recipient_email` invite target** (blind index only per ADR-0014).
  Nothing consumes it yet — the "links sent to me" inbox is not
  built. Add later when the receive-side surface exists.
- **QR code of the URL**. Nice-to-have. Not v1; `qr_flutter` is
  already a dependency (M2.5 fingerprint QR) so this is cheap to
  add when we want it.

### Separate `_LinkCreatedDialog` widget

Rather than making the existing `_SendCompleteDialog` render both
shapes, the link-mode result gets its own widget. The two dialogs
have almost nothing structurally in common (link dialog has the
URL as the primary content; app-mode dialog has file/recipient
metadata as the primary content) — sharing one code path would
require a lot of conditional rendering for negligible savings.

## Consequences

- **Existing app-mode flow is untouched.** The mode toggle defaults
  to "user" and the pre-existing send code path is a direct
  passthrough with an added `mode: SendMode.app` arg.
- **Link mode skips the entire recipient-lookup + fingerprint UI.**
  Faster path, but users who mis-toggle will notice: link mode has
  no address book affordance. That's correct — there's no recipient
  to look up.
- **Sender still signs `blob_sha256`.** The signature travels
  through to the wire, but the web decrypt page ignores it (server
  ADR-0035 documents why the browser doesn't verify). A future
  refactor could skip signing entirely in link mode, but it's cheap
  and preserves the option to verify later if we ever add
  authenticated links.
- **K_file leaves the encryption boundary as a base64url string in
  the URL.** This is by design (K_file lives in the fragment, never
  seen by the server) but it means "share the URL" ≡ "share the
  decryption key." Wording on the result dialog leans into this:
  *"anyone with this link can decrypt the file"*.
- **The share URL length is bounded**: 44 chars (path) + 43 chars
  (base64url K_file) + `#` + origin prefix. Under 200 characters
  total for `http://10.0.2.2:8000/…`. Fits SMS, chat, email
  without truncation.
- **New wire fields on initiate**: `mode`, `link_password`,
  `max_downloads`. All optional or default-valued — the existing
  app-mode tests aren't affected.

## Alternatives considered

- **Two separate methods `sendAppMode` / `sendLinkMode`.** Cleaner
  method signatures but duplicated the streaming pipeline. Rejected.
- **Automatic mode detection based on whether a recipient was
  looked up.** Confusing UX — the sender might not realize the
  send was in link mode until they saw the URL result. Explicit
  toggle wins.
- **Include filename in the URL as a query string** so a truncated
  share (URL without fragment) still shows the recipient something
  useful. Rejected: filename is inside the AEAD-encrypted
  enc_header for a reason — leaking it via the URL undoes the
  metadata-protection design. If the URL is truncated the recipient
  gets a friendly error (per web decrypt page).
- **Prompt for password AFTER encrypt+upload** (so the user gets
  the URL first and can optionally password-lock later). Doesn't
  work — the server-side password check happens at download time,
  gated by a hash stored at initiate time. Changing the hash after
  upload would require a separate mutation endpoint.
- **Skip the sender's `blob_sha256` signature in link mode.** Would
  save a few CPU-microseconds. Rejected — signing is cheap, and
  keeping the wire shape identical across modes reduces conditional
  code in `TransferService.send`.

## Open follow-ups

- **In-app link decrypt** — deep-link handler for
  `<host>/r/<id>#<K_file>` so a recipient on an installed app gets
  the same experience as the web page. Small branch once the web
  side is proven end-to-end.
- **QR code** in the result dialog for easy phone-to-phone sharing.
- **`recipient_email` invite target** wired through, once the
  "links sent to me" inbox exists.
- **Custom expiry / max_downloads presets** — surface if operator
  usage patterns want them.
- **`Share.share(url)` intent** (via `share_plus`) so the user can
  send the URL via any installed messaging app in one tap.
