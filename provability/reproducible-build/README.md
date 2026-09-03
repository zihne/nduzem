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

There are no tags in this repository yet. The first will be created with
the first release published after this convention was written.
