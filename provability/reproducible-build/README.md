# Reproducible builds (spec 13.1)

Pin toolchain (Flutter/Dart SDK, deps, flags); hermetic CI. Publish a per-release
build manifest: source commit, lockfile hashes, binary hash. verify.sh lets any
third party confirm the store binary matches public source.

**Not implemented yet.** `verify.sh` exits non-zero rather than reporting a
success it has not earned; see `../README.md` for what each piece needs.

## Release tag convention

`verify.sh <release-tag>` takes a tag as its only argument, so the tag is
the identifier the whole scheme hangs on. It has to name one build
unambiguously and for ever.

```
v<versionName>+<versionCode>        e.g. v0.1.0+38
```

Both halves come straight from `client/pubspec.yaml`'s `version:` line,
so the tag, the app's own version string and the Play `versionCode` all
agree by construction rather than by discipline.

**Why both halves.** `versionName` is what a user sees and can repeat
across builds; `versionCode` is what Play treats as the release identity
and must increase every upload. A tag naming only one of them cannot
distinguish two builds a user might have installed.

**Why `+` and not `-`.** It is semver build metadata, which is what a
build number is. A hyphen would make it a *pre-release* identifier, and
`0.1.0-38` sorts before `0.1.0` — the opposite of what is meant. The cost
is that `+` needs encoding as `%2B` in a URL, including GitHub release
links.

### Rules

- **One tag per Play release**, created at the commit the AAB was built
  from. `client/scripts/build-release.sh` prints the exact command.
- **Tags never move and are never deleted.** A repository ruleset
  enforces this with an empty bypass list, so changing one means
  deliberately editing the rule first. Verification against a movable tag
  proves nothing.
- **Tag after a successful upload, not before.** A tag that names a build
  Play rejected describes something no user can install.
- **The manifest is a release asset**, not only a committed file, and
  release immutability is enabled — so neither the tag nor the artefact
  it describes can be swapped after publication.

## What each tag actually attests

The guarantees are not uniform across the history, and the boundary is
worth stating plainly rather than leaving a reader to infer it from
signature badges.

### `v0.1.0+38` — the first production release, weaker than the rest

This tag records the build promoted to Google Play production in
September 2026. Three caveats apply to it and to no later tag:

- **The tag is unsigned**, and so is the commit it points at
  (`3aba888`). Both predate commit signing being configured on this
  repository.
- **The link between commit and binary is inferred, not embedded.** The
  AAB carries no commit identifier: `NDUZEM_GIT_COMMIT` was added to
  `build-release.sh` afterwards. The commit was established by comparing
  the AAB's build time against the commit log — the merge landed at
  10:20:44, the AAB was written at 10:24:56, and no commit exists between
  them. That is good evidence. It is not proof, and it is not something a
  third party can check independently.
- **The working tree was not verified clean at build time.** The
  clean-tree check was also added afterwards, so uncommitted changes
  cannot be ruled out by anything other than recollection.

It was left in place rather than deleted and recreated once signing
worked. Signing it would have placed a cryptographic attestation on the
strongest-looking part of a chain whose weakest link is the inference
above — and deleting a published tag to improve appearances is precisely
what the immutability rule exists to prevent. A documented boundary is
more honest than a tidied one.

### `v0.1.0+39` onward

From the next release, all three gaps are closed by
`client/scripts/build-release.sh`:

- The tag and its commit are both **signed**, and GitHub reports them
  verified.
- The commit SHA is compiled into the binary as `NDUZEM_GIT_COMMIT`, so
  the link is carried by the artefact rather than inferred from a
  timestamp.
- The build **refuses to run on a dirty working tree**, so the commit
  describes everything that went into it — untracked files included.

None of this yet amounts to a reproducible build. It establishes *which
source* a release claims to come from; proving that the source produces
that binary is what the rest of this directory is for, and it is not
implemented.
