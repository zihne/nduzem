# Provability

**Nothing in this directory is operational yet.** No independent audit has
been carried out, no release has been reproducibly built, and no warrant
canary is running. Everything here is scaffolding for claims we intend to
be able to make and cannot make today.

This file exists because the directory names alone — `audit/`,
`reproducible-build/`, `transparency/` — read at a glance as though those
things exist. They do not. Anyone skimming a public repository forms an
impression from the tree before they open a file, and that impression
should not be more favourable than the truth.

## Why publish it unfinished

The product's claim is that you should not have to trust us: the file is
encrypted on your device, and we hold ciphertext. But "you should not have
to trust us" is itself something you are currently being asked to take on
trust. The three mechanisms below are what would replace that with
something checkable:

- an **independent audit** — someone qualified confirms the implementation
  does what the design says;
- a **reproducible build** — you confirm the binary in the store was built
  from the source in this repository;
- a **warrant canary** — a signal about compelled disclosure that we could
  not otherwise give.

Publishing the gap is not an admission that undermines the product. The
gap exists whether or not it is written down; writing it down is the only
version where you can hold us to closing it.

## Status

| Component | Status | What closing it takes |
|---|---|---|
| `audit/` | **Not commissioned.** No third party has reviewed the cryptography or its implementation. | Engage a firm with applied-cryptography competence; publish the report in full, including findings we would rather not publish. Re-audit roughly every 18 months and after any change to the cryptographic design. |
| `reproducible-build/` | **Not implemented.** `verify.sh` deliberately exits non-zero; `build-manifest.template.json` is an empty shape. | Pin the toolchain (Flutter and Dart SDK versions, dependency lockfile, build flags), build hermetically in CI, publish a per-release manifest of source commit and binary hashes, and implement the four steps `verify.sh` documents. |
| `transparency/` | **Not operating.** See `transparency/warrant-canary.md` for why, including a legal complication specific to a UK company. | A signing key, a fixed schedule, and a process that survives illness and holidays — see that file. |

## What we do claim today

Only what can be checked from this repository as it stands: the source is
public and Apache-2.0 licensed, the cryptographic design is described in
the published whitepaper, and the limitations — including that content is
unreadable to us and therefore cannot be scanned for abuse — are stated in
the store listing rather than buried.

We do not describe the service as audited, verified, or reproducible, and
will not until the corresponding row above changes.
