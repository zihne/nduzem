# Nduzem Client (Flutter)
Apache-2.0. Reproducible builds: see ../provability/reproducible-build.
All encryption is client-side; the server never sees keys or plaintext.

## Toolchain

This project pins its Flutter SDK in `.fvmrc`, and the version there is
the one CI builds with. Use [fvm](https://fvm.app) so the pin is the
thing that actually runs:

```
brew tap leoafarias/fvm && brew install fvm
fvm install          # reads .fvmrc
fvm flutter pub get
fvm flutter test
```

Prefix every command with `fvm`, or run `fvm use` once per shell.

**Why not a single system-wide Flutter.** One shared SDK at `~/flutter`
means two projects on different versions cannot both build: switching
the checkout for one silently breaks the other. That is not theoretical
— it happened, and the symptom was unhelpful. `flutter pub get` failed
with *"Try using the Flutter SDK version: 3.47.7"*, which reads like a
dependency problem and is actually the SDK being too old: the real
constraint was `in_app_purchase_android >=0.4.0+11 which requires SDK
version >=3.10.0`, where *SDK* means **Dart**, not Flutter. Flutter
3.35.7 ships Dart 3.9.2.

A per-project pin removes the class of problem rather than that one
instance of it, and it leaves other projects on whatever they need.

**It is also a prerequisite we had already written down.**
`../provability/reproducible-build/README.md` opens with "Pin toolchain
(Flutter/Dart SDK, deps, flags); hermetic CI." Until now the SDK version
lived in one place — the CI workflow — and nothing connected it to a
developer's machine. `.fvmrc` is that pin, in the repository, where a
third party can read it.

If you change the version, change it in `.fvmrc`; CI fails if the
workflow disagrees.
