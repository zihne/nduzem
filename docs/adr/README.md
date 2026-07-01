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
