# Google Play Console — content-rating questionnaire

Answers we gave the Play Console content-rating flow for
OpaqueShare, with rationale. Update this file if we ever revise an
answer (Google occasionally rewords questions; product changes may
also shift answers).

**Baseline product characterisation.** Before the questionnaire
starts, Play Console asks for the app's broad category. We picked
the "utility / tool / reference" bucket — the first option — over
"Social or Communication" and "Game." OpaqueShare is a private,
end-to-end encrypted point-to-point file-transfer service. It has
no feed, no discovery, no chat. Its closest peers in the store
(WeTransfer, Send Anywhere, Filen, Dropbox, Google Drive) are all
listed under Productivity/Tools, none as Social. That's the honest
peer group.

## User Content Sharing questionnaire

| # | Question | Answer | Rationale |
|---|---|---|---|
| 1 | Does the app natively allow users to interact or exchange content with other users through voice communication, text, or sharing images or audio? | **Yes** | Files include images, audio, video, documents. |
| 2 | Is shared, user-generated content the **primary source** of content in the app? | **No** | Users don't browse other users' content. There's no feed, no discovery. OpaqueShare is a *transport* for user content (like email), not a *platform* where user-generated content is the product (like Instagram). |
| 3 | Does the app permit the **public sharing** of nudity? | **No** | No public sharing at all. Every transfer is point-to-point to a specific recipient the sender chose. Link-mode URLs go to an intended recipient, not to a public feed. A user pasting a link publicly would be a user misuse, not an app feature. |
| 4 | Does the app permit the **public sharing** of real-world, graphic violence outside of a newsworthy context? | **No** | Same reasoning as Q3 — no public sharing surface. |
| 5 | Does the app include the ability to **block** users or user-generated content? | **No** | No user-facing block UI at launch. (Server has an operator-side blocklist for platform moderation — ADR-0017 — but that's admin-only, not what this question asks about.) Follow-up: a client-side "block this sender" feature is queued for M9.x if abuse complaints surface. |
| 6 | Does the app include the ability to **report** users or user-generated content? | **No** | Server-side `/v1/reports/*` endpoint exists (ADR-0015, M7.1) but the client UI hasn't been wired at launch. Follow-up: adding a "Report this transfer" button on the receive screen is a small client change, kept as an option to strengthen this answer if Google Trust & Safety flags Q5+Q6 both being "No." |
| 7 | Does the app include chat moderation? | **No** | No chat feature exists → nothing to moderate. |
| 8 | Can interactions in the app be limited to **invited friends only**? | **Yes** | This is the core mitigation. **App-mode:** the sender must know the recipient's email or handle out-of-band before they can send anything — no discovery, no in-app "find users nearby." **Link-mode:** the sender explicitly shares the URL with an intended recipient of their choice. Zero public discoverability. No "stranger can message you unsolicited" shape exists. |

## Content, promotion, purchases + miscellaneous sections

Play Console follows the User Content Sharing block with several
shorter sections covering catalog content, age-restricted products,
location sharing, in-app purchases, and app-type flags. Answers:

| # | Question | Answer | Rationale |
|---|---|---|---|
| A | Features or promotes content that isn't part of the initial app download but can be accessed from the app? (Examples given: Netflix movies, Amazon listings, Spotify songs, generated AI content, NYT articles.) | **No** | The examples are publisher-curated content catalogs. OpaqueShare has none of that shape — no catalog, no feed, no discovery, no curation, no in-app content library. Files a recipient sees were sent point-to-point by a specific person they know out-of-band. Same shape as email attachments; nobody would answer Yes to this question about Gmail. |
| B | Focus on promoting or selling age-restricted products (cigarettes, alcohol, firearms, gambling)? | **No** | The app isn't a marketplace and doesn't promote any of these. User-transferred content is the users' — the app is a transport. |
| C | Share the user's current, precise physical location with other users? | **No** | No location permissions, no `geolocator` dependency, no lat/long ever leaves the device. Transfers don't attach location metadata (a user-uploaded photo may contain its own EXIF, but the app doesn't extract, expose, advertise, or share it). |
| D | Allow users to purchase digital goods? | **Yes** | IAP: credit packs (consumable, non-transferable storage/bandwidth allowance) + auto-renewing subscriptions. All through Google Play Billing. |
| E | Cash rewards, gift cards, play-to-earn, convertible crypto rewards, transferable digital assets (NFTs)? | **No** | Credit packs are non-transferable, non-convertible, spendable only inside OpaqueShare. No token, no NFT, no cash-out mechanism. |
| F | Is the app a web browser or search engine? | **No** | |
| G | Is the app primarily a news or educational product? | **No** | It's a utility / file-transfer tool. |

### Notes on the tricky ones

**Q A (content accessed from the app).** The wording is broad
enough that a literal reading might include received files, but the
examples make the intent unambiguous — this question targets
publisher-curated content catalogs. Same shape as email, which
nobody would answer Yes to. If Google ever asks for clarification,
say: "point-to-point private transfers between users the sender
specified — no catalog, no discovery, no curation."

**Q D (purchase digital goods).** Answering Yes unlocks a follow-up
flow about **whether purchases go through Google Play Billing**
(yes), **what's being sold** (consumable credit packs + auto-
renewing subscriptions), and **whether prices differ by region**
(deferred per pricing/regions memory). Have the product SKUs from
the seeded catalog ready when that flow appears — `credit_starter`,
`credit_standard`, `credit_pro`, `sub_personal`, `sub_pro`.

## Why this combination is honest

Answering **Yes to Q1** and **Yes to Q8** together is the accurate
description of a private invited-communication service. Play Console
weights Q8 heavily — invite-only apps face a substantially lower
abuse-risk exposure than open messaging platforms, because a user's
"attack surface" is limited to people they've explicitly given their
handle to.

We deliberately did NOT answer Yes to Q5 / Q6 without wiring the
features — that would be misrepresenting the product to Google. The
follow-up items (client-side block/report UI) are legitimate M9.x
work, tracked separately.

## Expected outcome

Given no violence / drug use / gambling / sexual content in the app
itself (all "No" answers in the subsequent sections of the
questionnaire), and given the Q1+Q8 combination above, we expect a
low content-rating class (roughly **PEGI 3+ / IARC Everyone**).

If Google returns a higher rating than expected, likely reasons:

- **Q5 + Q6 both No** — Google Trust & Safety sometimes wants at
  least one abuse-mitigation feature on any app with UGC exchange.
  The mitigation is to ship the client-side "Report this transfer"
  UI (small — ~50 lines of Dart calling an existing endpoint) and
  re-submit.
- **A subsequent question** we haven't captured here yet, in which
  case we update this file with the new answer + rationale.

## Data Safety questionnaire (companion to content rating)

Google's Data Safety section is a separate submission from content
rating, but the answers are of the same nature — we capture them
here so the whole first-submission provenance lives in one place.

| # | Question | Answer | Rationale |
|---|---|---|---|
| DS1 | Does your app collect or share any of the required user data types? | **Yes** | Email, optional handle, password hash, purchase tokens (IAP), IP (rate limiting), MFA secret (if enrolled), device push token (M2.5). Files are ciphertext-only from the server's POV but still count as "user data collected" per Google's definition. |
| DS2 | Is all of the user data collected by your app encrypted **in transit**? | **Yes** | HTTPS everywhere — FastAPI behind Caddy TLS termination in the prod-compose stack; R2 file uploads/downloads use HTTPS presigned URLs. Transfers additionally get end-to-end encryption (X25519 + secretstream) so the server never sees plaintext; in-transit encryption is a strict subset of what we actually provide. |
| DS3 | Which methods of account creation does the app support? | **Username and password** + **Username, password, and other authentication** | Initial account creation uses email + password (register flow). MFA (TOTP) is enrolled post-creation via a separate flow. Selecting both variants covers the MFA-off and MFA-on cohorts accurately. No OAuth / social login. |
| DS4 | Delete-account URL | **`https://opaqueshare.com/account-deletion.html`** | Live page served by the marketing site (`opaqueshare-server` repo, `infra/www/account-deletion.html`). Covers Google's requirements: developer name, in-app deletion steps, email fallback, per-field retention list. Content sourced from server ADR-0025. |

### Delete-account URL — content

The live page is at
**`https://opaqueshare.com/account-deletion.html`** — source
maintained in `opaqueshare-server/infra/www/account-deletion.html`.
The template below is the canonical wording; the live page follows
it verbatim (with HTML wrapping). Keep the two in sync when the
retention policy in server ADR-0025 changes.

```
Delete your OpaqueShare account

To delete your OpaqueShare account and associated data:

1. Open the OpaqueShare app on your device.
2. Go to Settings → Delete my account.
3. Type the confirmation phrase and enter your password.
4. Tap Delete.

If you can't access the app, email support@opaqueshare.com with your
registered email address and ask for account deletion. We'll process
the request within 30 days per GDPR Article 17.

What gets deleted immediately:
- Your email address
- Your handle (username)
- Your password hash
- Your MFA / recovery codes
- Your active session + device tokens
- Any pending file transfers not yet downloaded by the recipient

What's retained (pseudonymised — no longer linked to you personally):
- Your user ID (a UUID) — required because past transfers and audit
  records reference it
- Your public keys — required so recipients of past transfers can
  still verify signatures
- Admin audit-log entries — retention required for legal / compliance
  purposes
- Aggregated usage counts — non-identifying, kept indefinitely

Data hosting: All account data is stored in the European Union
(exact regions per operator setup).

Contact: support@opaqueshare.com  |  Developer: <operator name>
```

This wording maps 1:1 to server ADR-0025 (`retained_notice` field
in the erasure response). If the ADR text changes, update this
template + the deployed page in the same PR.

### Placement + hosting — locked in

Chose option 1 (Caddy-served static site on the same Lightsail VM
as the API). Implementation:

- Marketing site lives at `opaqueshare-server/infra/www/`.
- Caddy serves the bare domain (`opaqueshare.com`) from a
  bind-mounted `/srv/www` directory.
- The `/r/*` path proxies to the API's existing web decrypt page so
  transfer links stay on the bare domain.
- `api.opaqueshare.com` continues to serve the API surface —
  end users don't navigate there directly.
- `.well-known/assetlinks.json` served from `/srv/www/.well-known/`
  (see server repo `infra/www/.well-known/README.md` for the
  operator TODO on fingerprint filling).

See the server-side branch `feat/www-marketing` for the full
implementation + Caddyfile / compose changes.

## Change log

| Date | Change | Reason |
|---|---|---|
| 2026-07-07 | Initial answers captured during Play Console setup for the first Android release. | Provenance record for the first submission. |
| 2026-07-07 | Added content, promotion, purchases + miscellaneous sections (Qs A-G) — content catalog, age-restricted, location, digital goods, digital assets, browser/search, news/education. | Continued the same submission round; captured as answered. |
| 2026-07-07 | Added Data Safety section (DS1-DS4) — collection, transit encryption, account-creation methods, delete-account URL template. | Data Safety is a separate submission but same first-launch round; consolidated for provenance. |
| 2026-07-07 | Delete-account URL landed at `https://opaqueshare.com/account-deletion.html` (server repo `feat/www-marketing`). Updated DS4 answer + hosting-options section. | Marketing site launch unblocks Data Safety submission. |
