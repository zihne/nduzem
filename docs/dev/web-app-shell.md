# Web app — shell status + follow-ups

Companion to the [scale-to-business roadmap Workstream 3](../../../opaqueshare-server/docs/roadmap/2026-scale-to-business.md).
This doc captures the state after `feat/web-app-shell` and what
remains for later web-app branches.

## What works on this branch

- **The main Flutter app compiles to web** cleanly:
  ```
  flutter build web \
    --dart-define=OPAQUESHARE_API_BASE=https://api.opaqueshare.com \
    --dart-define=OPAQUESHARE_SHARE_URL_BASE=https://opaqueshare.com
  ```
  ~41 s cold, ~10 s warm. Output at `client/build/web/`.

- **`sodium_libs` loads via `web/sodium.js`** (set up on the earlier
  `feat/web-app-scaffold` branch; `flutter pub run
  sodium_libs:update_web` installs it if it ever goes missing).

- **Auth flow paths reach without crashing on web:**
  - `/` (home)
  - `/login`, `/register`, `/login/totp`
  - `/verify-email`, `/password-reset`
  - `/inbox`, `/history`
  - `/paywall` — the `Platform.isIOS` probe was gated with `kIsWeb`
    on this branch so navigating to it doesn't crash; the STUB fallback
    catalog is fetched.

- **All existing mobile tests still pass** (152/152). The `kIsWeb`
  guards are additive — mobile continues to hit the Platform branches
  it always did.

## What definitely does NOT work yet on web

Reachable but broken; needs its own branch to fix. Do NOT hand a web
URL to a user expecting these to work.

### File send / receive (biggest gap)

- `send_screen.dart`, `receive_screen.dart`, `link_receive_screen.dart`,
  `batch_send_screen.dart` all import `dart:io` and use `File(...)`,
  `getApplicationDocumentsDirectory()`, etc. On web these throw
  `UnsupportedError` at runtime.
- `transfer_service.dart` streams from disk via `File.openRead()` —
  no equivalent on web (browsers use `File` from `dart:html` / `Blob`
  slicing).
- The proven-good `sodium_libs` streaming crypto path (see
  [sodium-web-smoke-test.md](sodium-web-smoke-test.md)) works, but
  the input side needs a browser-native `File` → `Stream<List<int>>`
  bridge. Belongs on **`feat/web-app-send-receive`**.

### Storage caveats

- `flutter_secure_storage_web` uses IndexedDB with a per-origin AES
  key stored in `window.crypto.subtle`. **Data is per-origin and
  per-browser** — a user signed in on `app.opaqueshare.com` in Chrome
  has NO shared state with the same user on mobile.
- Which means: **first login on the web app is always "fresh device"**
  from ADR-0011's perspective. The user has to re-register OR log in
  with an existing account and accept that received-transfer decrypt
  won't work (private keys aren't on this device).
- Long-term fix: some form of secure key export/import
  (QR-scan-your-mobile-to-web pairing, or a paper-backup path). Big
  scope; not v1.

### Link-mode receive at `/r/:transferId` on web

- Router accepts the path (matches mobile), but `LinkReceiveScreen`
  uses `dart:io File` + `Platform.isAndroid` and would crash on web.
- Not urgent because shared links point at `opaqueshare.com/r/<id>`
  (marketing domain) which serves the server-rendered web decrypt
  page (server ADR-0035). The Flutter web app at
  `app.opaqueshare.com/r/<id>` is a redundant route today; either
  make it work in the web-send-receive branch, or make the router
  redirect to the marketing site on web.

### Deep-linked in-app purchase

- Play Billing / StoreKit don't exist on web. The `IapPurchaseService`
  already falls through to the STUB receipt path on web (via
  `playAvailable → false`). But the STUB path talks to the API and
  actually credits balances — **on prod, we probably don't want web
  visitors to be able to purchase via STUB.**
- v1 web app should show a "buy on mobile" CTA on the paywall
  instead of surfacing STUB purchases. Belongs on
  **`feat/web-app-history-settings`** (paywall polish).

### Deployment

- No Caddy handle block for `app.opaqueshare.com` yet.
- No CORS entry for `app.opaqueshare.com` on the API (`api.opaqueshare
  .com` currently allows `opaqueshare.com` and `api.opaqueshare.com` —
  the web app will get CORS-blocked calling `/v1/*` from
  `app.opaqueshare.com`).
- Belongs on **`feat/web-app-deploy`** with the DNS + Caddy work.

## Wasm build (deferred)

`flutter build web --wasm` fails with:

```
package:flutter_secure_storage_web/... uses dart:html (0), dart:js_util (15)
```

These deprecated JS-interop APIs block wasm. Not blocking for v1
(standard JS build works fine). If wasm becomes important for perf
later, the fix is upstream — file an issue on `flutter_secure_storage`
or migrate to a `package:web`-based storage plugin.

## Testing the shell locally

```bash
cd client
flutter run -d chrome --target=lib/main.dart \
  --dart-define=OPAQUESHARE_API_BASE=https://api.opaqueshare.com \
  --dart-define=OPAQUESHARE_SHARE_URL_BASE=https://opaqueshare.com
```

Or against the local dev API:

```bash
flutter run -d chrome --target=lib/main.dart \
  --dart-define=OPAQUESHARE_API_BASE=http://localhost:8000 \
  --dart-define=OPAQUESHARE_SHARE_URL_BASE=http://localhost:8000
```

Note that the localhost variant requires the dev API to have CORS
open to `http://localhost:5000` or whatever port Chrome picks.

## The remaining web-app branches

| Branch | Scope | Est. |
|---|---|---|
| `feat/web-app-send-receive` | Browser File API → `sodium_libs` streaming bridge; send + receive screens for web; keep mobile paths intact | 2-3 weeks |
| `feat/web-app-history-settings` | History + settings screens web-polished; paywall shows "buy on mobile" on web | ~1 week |
| `feat/web-app-deploy` | Caddy handle block for `app.opaqueshare.com`, DNS, API CORS entry, cross-browser QA | ~1 week |

Order matters. Send/receive is the biggest chunk; do it first so the
web app has actual value before we deploy anywhere.
