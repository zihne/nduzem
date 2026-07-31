# Architecture Decision Records (client)

Public-repo ADRs for the OpaqueShare Flutter client + provability tooling.
These sit alongside the server-side ADRs (in the separate private
`opaqueshare-server` repo) and follow the same format: Context / Decision /
Consequences / Alternatives considered / Open follow-ups. Amendments are new
ADRs, not edits to older ones.

## Format

Use the next free 4-digit number. Filename: `NNNN-short-kebab-slug.md`.

Status conventions:

- **Proposed**: drafted, not yet locked in.
- **Accepted**: in effect.
- **Superseded by ADR-MMMM**: replaced. Leave the file in place.
- **Deprecated**: no longer relevant, kept for context.

## Index

| # | Title | Status |
|---|---|---|
| [0001](0001-m1-client-architecture.md) | M1 — client architecture (Riverpod + go_router + libsodium) | Accepted |
| [0002](0002-m3.3-play-billing-client.md) | M3.3 — Play Billing client integration | Accepted |
| [0003](0003-m4-client-multipart.md) | M4 — client chunked secretstream + multipart upload | Accepted |
| [0004](0004-m4-streaming-send.md) | M4 — client streaming send from disk | Accepted |
| [0005](0005-m5-link-mode-sender.md) | M5 — client-side link-mode sender | Accepted |
| [0006](0006-m4-streaming-receive.md) | M4 — client streaming receive to disk | Accepted |
| [0007](0007-client-transfer-history.md) | Client — local transfer history | Accepted |
| [0008](0008-saf-stream-save.md) | Native SAF stream-save for large-file receive (Android) | Accepted |
| [0009](0009-multi-file-batch-send.md) | Multi-file batch send (app mode) | Accepted |
| [0010](0010-in-app-link-decrypt.md) | In-app link-mode receive (deep-link `/r/<id>#<K>`) | Accepted |
| [0011](0011-per-user-secure-storage.md) | Per-user secure_storage for identity keypairs | Accepted |
| [0012](0012-per-user-local-persistence.md) | Per-user local persistence for transfer history + verified contacts | Accepted |
| [0013](0013-web-send-receive-streaming.md) | Web send + receive: streaming pipeline unified across mobile and web | Accepted |
| [0014](0014-defer-crypto-metadata-to-commit.md) | Defer per-transfer crypto metadata from `/initiate` to `/commit` (amends ADR-0013) | Accepted |
| [0015](0015-ios-platform-parity.md) | iOS platform parity: Info.plist, entitlements, universal links | Accepted |
