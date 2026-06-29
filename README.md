# OpaqueShare — privacy-first file transfer (client)

OpaqueShare lets a sender transmit a file to a recipient such that **the
server never holds keys or plaintext**. The operator can see who sent what
to whom and how big the blob was, but cannot see the file contents,
filename, or type. All cryptography happens on the user's device.

This repository contains the **client and verification artifacts**:
- [client/](client/) — Flutter app (iOS + Android). Apache-2.0 licensed.
- [provability/](provability/) — reproducible-build pipeline, audit reports
  (when available), transparency reports, and warrant canary.

The backend (FastAPI conduit + infrastructure) is **not** open source.

## Core invariants

- File bytes flow client ⇄ object storage directly; they never traverse the
  backend.
- The server stores only ciphertext, wrapped keys it cannot open, and
  routing metadata.
- Every envelope carries a `crypto_suite` identifier so a future
  post-quantum suite can coexist with classical ciphertext without breaking
  old blobs.
- Burn-after-confirmed-receipt with a 7-day TTL backstop, whichever comes
  first.

## Honest scope (read before believing marketing)

- "Burn after reading" means the **server** deletes its copy. It does **not**
  delete the recipient's decrypted local copy.
- Content scanning is structurally impossible in this design. Abuse response
  is reactive, report-driven, and behavior-based — never server-side content
  inspection.
- The client crypto stack is classical (X25519 + Ed25519 + XChaCha20-Poly1305).
  A hybrid post-quantum suite is planned for v2; v1 is migration-ready via
  `crypto_suite` versioning.
- The phrase **"zero-knowledge"** is not used in marketing until an
  independent third-party audit of the cryptographic design and client
  implementation has been published. The accurate phrasing for now is *"the
  server never holds keys or plaintext."*

## Verifying a release

> The verification toolchain is under construction; details below describe
> the target workflow.

For every released build, this repository publishes a **build manifest**
recording the exact source commit, dependency lockfile hashes, and the
resulting binary hash. To confirm that the app you installed from the App
Store / Play Store matches this source:

```
./provability/reproducible-build/verify.sh <release-tag>
```

This recomputes the binary in a hermetic container and compares its hash to
the published manifest. Any divergence is reported.

## License

Client source (this repository): **Apache-2.0** — see
[LICENSE-client.md](LICENSE-client.md). The Apache patent grant covers
contributors and downstream users.

The OpaqueShare backend is proprietary and lives in a separate, private
repository.

## Status

Pre-launch. There is no public app to install yet. This repository will be
made public when the client reaches a verifiable beta.
