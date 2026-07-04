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
