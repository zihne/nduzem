# Web app — status + deployment

Companion to the [scale-to-business roadmap Workstream 3](../../../nduzem-server/docs/roadmap/2026-scale-to-business.md).
Started as the `feat/web-app-shell` handover; now covers everything
that landed through Phase 7 + the deploy plumbing.

## What ships today

- Full parity with mobile on send + receive (both app + link mode),
  inbox, history, verify-contact.
- Streaming send: encrypt-in-browser + upload-in-parts, peak memory
  ≈ 5 MiB regardless of file size (ADR-0013).
- Streaming receive: download + decrypt into a browser Blob; save via
  File System Access API on Chromium or `<a download>` fallback on
  Firefox / Safari (ADR-0013 Phase 6).
- Transfer history persisted in `localStorage`, per user id.
- Paywall shows a "buy in the mobile app" nudge on web instead of the
  purchase tiles (Google / Apple IAP handles VAT / sales-tax
  remittance for us).
- Layout is capped at 720 px + centered on wide viewports, so desktop
  browsers don't get a stretched mobile UI.
- Branded PWA — icons + `manifest.json` + favicon all match the
  deepPurple app theme.

Cross-browser QA checklist for what to verify by hand on each browser:
[docs/dev/web-cross-browser-qa.md](web-cross-browser-qa.md).

## Deploying

Web bundle compiles on your dev machine and `rsync`s to the prod
box. Caddy on the server serves the static files at
`https://app.nduzem.com`. **Nothing Flutter-related runs on the
server** — just the existing Caddy container.

### One-time setup

1. **DNS** — A / AAAA record for `app.nduzem.com` pointing at
   the prod box. ACME provisions the cert on the first HTTPS request
   once DNS resolves.
2. **CORS** — the api service's `CORS_ALLOWED_ORIGINS` env must
   include `https://app.nduzem.com`. Already in
   `infra/docker/.env.prod.example` on the server repo; check your
   actual `.env.prod` on the box.
3. **Caddy reload** — the first time the `app.` vhost lands on the
   server:
   ```bash
   docker compose -f infra/docker/docker-compose.prod.yml \
     exec caddy caddy reload --config /etc/caddy/Caddyfile
   ```

### Every release

```bash
# On your dev machine
cd client
scripts/build-web-release.sh \
  https://api.nduzem.com \
  https://nduzem.com

# Push to prod (Caddy serves the new files immediately — bind-mount)
rsync -av --delete build/web/ \
  prod:/opt/nduzem-server/infra/www-app/
```

[`scripts/build-web-release.sh`](../../client/scripts/build-web-release.sh)
runs the full preflight (analyze + tests) before building, and prints
the exact `rsync` command to copy for step 2. Mirrors the mobile
`build-release.sh` pattern.

The rsync target path assumes the server repo lives at
`/opt/nduzem-server/` on the box. Adjust for your actual
clone location. The bind-mount source is
[`infra/www-app/`](../../../nduzem-server/infra/www-app/README.md)
in the server repo (see the README there for the same workflow from
the server-repo perspective).

## Known caveats

### Storage is per-origin

`flutter_secure_storage_web` and the transfer-history localStorage
both live under the `app.nduzem.com` origin. A user signed in
on the web has NO shared state with themselves on mobile.

Practical consequence: **first web login is always "fresh device"**
from ADR-0011's perspective. The user has to re-register OR log in
with an existing account and accept that received-transfer decrypt
won't work (their private keys aren't on this device).

Long-term fix: some form of secure key export/import
(QR-scan-your-mobile-to-web pairing, or a paper-backup path). Big
scope; not v1.

### Link-mode receive at `/r/:transferId`

`app.nduzem.com/r/<id>` is a redundant route today — shared
links point at `nduzem.com/r/<id>` (marketing domain) which
serves the server-rendered web decrypt page (server ADR-0035). The
Flutter web app's link-receive path works, but users won't naturally
land on it. Not a bug, just a routing overlap to be aware of.

### Wasm build (deferred)

`flutter build web --wasm` fails with:

```
package:flutter_secure_storage_web/... uses dart:html (0), dart:js_util (15)
```

These deprecated JS-interop APIs block wasm. Not blocking for v1 —
the standard JS build works fine. If wasm becomes important for perf
later, the fix is upstream — file an issue on `flutter_secure_storage`
or migrate to a `package:web`-based storage plugin.

## Testing the shell locally

```bash
cd client
flutter run -d chrome --web-port=5173 --target=lib/main.dart \
  --dart-define=NDUZEM_API_BASE=http://localhost:8000 \
  --dart-define=NDUZEM_SHARE_URL_BASE=http://localhost:8000
```

Pin `--web-port=5173` (or 5000 / 8080) — the dev backend's CORS
allowlist only covers those localhost ports out of the box. To add
another, set `CORS_ALLOWED_ORIGINS=http://localhost:<port>` on the
api service in `infra/docker/docker-compose.dev.yml`.

## Historical: the web-app phase list

For posterity — the phased rollout ADR-0013 called for, all now
merged into main:

| Branch | What it did |
|---|---|
| `feat/web-send-1-plaintext-source` | `PlaintextSource` abstraction |
| `feat/web-send-2-encrypt-stream` | `FileCrypto.encryptToStream` |
| `feat/api-metadata-at-commit` | Server contract change (ADR-0014 / server ADR-0037) |
| `feat/web-send-3-transfer-service` | Streaming send pipeline, temp-file staging retired |
| `feat/web-send-4-web-implementations` | `BlobPlaintextSource` + browser file picker |
| `feat/web-receive-1-decrypt-stream` | `FileCrypto.decryptToStream` + `PlaintextDestination` |
| `feat/web-receive-2-blob-save` | FSA / `<a download>` save on web |
| `feat/web-send-receive-polish` | Large-screen layout, oversized-file error copy, cancel-in-flight polish |
| `feat/web-progress-and-qa` | Single-figure progress bar, cross-browser QA checklist |
| `feat/web-transfer-history` | `localStorage` history on web |
| `feat/web-branding-and-paywall-nudge` | Web icons + manifest, "buy in mobile app" nudge |
| `feat/web-app-deploy` (server) + `feat/web-release-build-script` (client) | Caddy vhost + rsync deploy workflow |
