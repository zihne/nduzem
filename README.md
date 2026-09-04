# Nduzem - privacy-first file transfer (client)

Nduzem lets a sender transmit a file to a recipient such that **the
server never holds keys or plaintext**. The operator can see who sent what
to whom and how big the blob was, but cannot see the file contents,
filename, or type. All cryptography happens on the user's device.

This repository contains the **client and verification artifacts**:
- [client/](client/): Flutter app: **Android and web** shipped, **iOS under
  construction**. Apache-2.0 licensed.
- [provability/](provability/): scaffolding for reproducible builds, audit
  reports and transparency signals. **None of it is operational yet**; see
  [provability/README.md](provability/README.md) for the status of each and
  what closing the gap takes.

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
  is reactive, report-driven, and behavior-based; never server-side content
  inspection.
- The client crypto stack is classical (X25519 + Ed25519 + XChaCha20-Poly1305).
  A hybrid post-quantum suite is planned for v2; v1 is migration-ready via
  `crypto_suite` versioning.
- We do describe Nduzem as **zero-knowledge**, and we mean something
  specific and narrow by it: the server never holds your keys or your
  plaintext, and cannot derive either. That is a claim about the
  architecture, and it is checkable, against the client source in this
  repository, and against the protocol in the security whitepaper. You do
  not have to take it on trust, which is the point.
  It is **not** a claim that anyone independent has verified it. No external
  audit of the cryptographic design or the client implementation has been
  published. When one is, it will be linked here and in
  [provability/audit/](provability/audit/). Until then, "zero-knowledge"
  here describes what the design makes impossible, not what an auditor has
  confirmed.

## Verifying a release

> **The verification toolchain is under construction; the workflow below
> is the target, not the current state.** `verify.sh` is not implemented
> and **exits non-zero**: it verifies nothing today, and says so rather
> than reporting a success it has not earned.

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

Client source (this repository): **Apache-2.0**, see
[LICENSE-client.md](LICENSE-client.md). The Apache patent grant covers
contributors and downstream users.

The Nduzem backend is proprietary and lives in a separate, private
repository.

## Status

**Live.** Android is on Google Play, and the web client runs at
[app.nduzem.com](https://app.nduzem.com). **iOS is the remaining piece**
and is under construction.

This repository was made public in September 2026, at launch.

An earlier version of this section said it would be published "when the
client reaches a verifiable beta". That was changed deliberately, and it
is worth saying so rather than letting the promise disappear: the
verification toolchain in [provability/](provability/) is still
scaffolding, `verify.sh` exits non-zero, and waiting for it would have
meant shipping an app whose central claim nobody could read the source of
for months.

Readable code now is worth more than verifiable builds later. They are
not the same thing, and [provability/README.md](provability/README.md)
sets out exactly which pieces are missing.
