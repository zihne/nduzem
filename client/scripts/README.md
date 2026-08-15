# `client/scripts/`

Operator scripts for producing distributable Nduzem client
artefacts. Intended for local + CI use; not shipped in the app.

## `build-release.sh`

Builds a Play-Store-ready AAB with every pre- and post-flight check
inline. Run from anywhere; the script `cd`s to the client repo root
itself.

```bash
scripts/build-release.sh https://api.nduzem.com
```

Or with the URL in an env var:

```bash
NDUZEM_API_BASE=https://api.nduzem.com scripts/build-release.sh
```

### What it checks, in order

1. Flutter is on PATH.
2. `android/key.properties` exists and its `storeFile` points at a
   real `.jks`. (Without this, `flutter build appbundle` silently
   signs with the debug key and Play Console rejects the AAB.)
3. `flutter clean` succeeds.
4. `flutter pub get` succeeds.
5. `flutter analyze` is clean.
6. `flutter test` passes.
7. `flutter build appbundle --release` produces an AAB at
   `build/app/outputs/bundle/release/app-release.aab`.
8. The AAB is signed with a real release cert (**not** the debug
   key's `CN=Android Debug`).
9. The merged Android manifest does **not** silently declare
   `com.google.android.gms.permission.AD_ID`. (See the compliance
   doc on the server for the fallback recipe if a future dep injects
   it.)
10. Prints a summary: AAB path, size, version, signing SHA-256, and
    the "next steps" checklist (assetlinks.json update reminder +
    upload path).

Any check failure exits non-zero with a message on stderr explaining
what to fix. On success, the AAB is ready to upload to Play Console.

### When to use

- **Before every Play Console upload** — internal testing or
  production. Catches all the common release-blocker issues in one
  go instead of Play Console rejecting the AAB hours later.
- **In CI** if you set one up — the script's exit code is CI-safe.

### When NOT to use

- Local iteration on the app — use `flutter run` / `flutter build
  apk --debug` directly. This script is deliberately strict (fails
  on any analyze / test issue) and slow (full clean + test suite).

### First-time setup

If `android/key.properties` doesn't exist yet:

```bash
keytool -genkey -v \
  -keystore ~/nduzem-upload.jks \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -alias upload

cp android/key.properties.example android/key.properties
$EDITOR android/key.properties
# Fill in the four values with the passwords you just chose.
```

See `android/key.properties.example` for the file format and
per-field notes.
