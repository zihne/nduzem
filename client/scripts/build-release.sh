#!/usr/bin/env bash
#
# build-release.sh — build a Play-Store-ready Nduzem AAB with
# every pre- and post-flight check inline.
#
# What it does, in order:
#   1. Verify Flutter is on PATH.
#   2. Verify android/key.properties + the referenced keystore exist.
#      (Without them, `flutter build appbundle` silently signs with
#      the debug key and Play Console rejects the AAB.)
#   3. `flutter clean` — drop stale build artefacts.
#   4. `flutter pub get` — fetch deps.
#   5. `flutter analyze` — must be clean.
#   6. `flutter test` — full suite must pass.
#   7. `flutter build appbundle --release` with the API base URL
#      threaded through as a `--dart-define`.
#   8. Verify the AAB is signed with a release cert (NOT the debug
#      cert `CN=Android Debug`).
#   9. Verify the merged Android manifest does NOT declare
#      `com.google.android.gms.permission.AD_ID` — Play Console
#      blocks releases whose declared "advertising ID: no" answer
#      disagrees with the shipped manifest.
#  10. Print AAB path, size, version, signing SHA-256, and next
#      steps (assetlinks.json + upload).
#
# Exit code 0 means the AAB at
# `build/app/outputs/bundle/release/app-release.aab` is ready to
# upload. Any non-zero exit is a hard failure with a message on
# stderr explaining what to fix.
#
# Usage:
#   scripts/build-release.sh [NDUZEM_API_BASE]
#
# Or via env var:
#   NDUZEM_API_BASE=https://api.nduzem.com scripts/build-release.sh
#
# The API base MUST be an https:// URL for a production build. The
# script warns (but doesn't fail) on http:// so you can still run it
# against a local tunnel for pre-flight testing.

set -euo pipefail

# --- terminal colours (auto-disabled when piped) --------------------
if [[ -t 1 ]]; then
    C_RED=$'\033[0;31m'
    C_GREEN=$'\033[0;32m'
    C_YELLOW=$'\033[0;33m'
    C_BLUE=$'\033[0;34m'
    C_BOLD=$'\033[1m'
    C_RESET=$'\033[0m'
else
    C_RED=''
    C_GREEN=''
    C_YELLOW=''
    C_BLUE=''
    C_BOLD=''
    C_RESET=''
fi

say()  { printf '%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()   { printf '%s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s⚠%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
fail() {
    printf '%s✗ %s%s\n' "$C_RED" "$*" "$C_RESET" >&2
    exit 1
}

# --- resolve arguments -----------------------------------------------
API_BASE="${1:-${NDUZEM_API_BASE:-}}"
if [[ -z "$API_BASE" ]]; then
    fail "NDUZEM_API_BASE is required.

Usage:
  scripts/build-release.sh https://api.nduzem.com [https://nduzem.com]

Or:
  export NDUZEM_API_BASE=https://api.nduzem.com
  scripts/build-release.sh"
fi

case "$API_BASE" in
    https://*) ;;
    http://*)  warn "API base is http:// — release builds should use https:// in production." ;;
    *)         fail "API base must be a full URL (starts with http:// or https://). Got: $API_BASE" ;;
esac

# Share URL base — where link-mode share URLs point. Falls back to
# stripping `api.` from the API host (client's AppConfig does the same
# derivation, so passing this arg explicitly is optional when the
# `api.<host>` / `<host>` convention holds).
SHARE_URL_BASE="${2:-${NDUZEM_SHARE_URL_BASE:-}}"
if [[ -z "$SHARE_URL_BASE" ]]; then
    # Derive by stripping a leading `api.` from the URL's host.
    #
    # Was `${API_BASE/\/\/api./\/\/}`, which is broken: bash keeps the
    # backslashes in the replacement half of a pattern substitution, so
    # it produced `https:\/\/nduzem.com` and then tripped the
    # validation below with a message that blamed the input. It failed
    # safe rather than baking a malformed URL into a release, but the
    # "omit the second argument" path never actually worked.
    SHARE_URL_BASE="$(printf '%s' "$API_BASE" | sed 's|//api\.|//|')"
    if [[ "$SHARE_URL_BASE" == "$API_BASE" ]]; then
        warn "Could not derive a share URL base from API base — no 'api.' prefix.
Falling back to the API base as the share host. Set
NDUZEM_SHARE_URL_BASE explicitly if this is wrong for your setup."
    fi
fi

case "$SHARE_URL_BASE" in
    https://*|http://*) ;;
    *) fail "Share URL base must be a full URL. Got: $SHARE_URL_BASE" ;;
esac

# --- work from the client-repo root ----------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$CLIENT_ROOT"

# --- 1. Flutter available --------------------------------------------
say "Checking Flutter is on PATH…"
command -v flutter >/dev/null || fail "flutter not on PATH."
# Capture the whole stream before slicing it. `flutter --version | head -1`
# looks harmless but breaks intermittently: head exits after one line, and
# when flutter then tries to print its "a new version is available" box the
# closed pipe raises SIGPIPE, which the Dart tool does not handle — it dies
# with an unhandled FileSystemException and takes the build with it. The
# failure only appears when flutter happens to have an upgrade notice, so it
# looks random and unrelated to whatever else changed.
_flutter_version="$(flutter --version 2>/dev/null)"
printf '%s\n' "${_flutter_version%%$'\n'*}"
ok "Flutter ready"

# --- 2. Release signing config exists --------------------------------
say "Checking release signing config…"
KEY_PROPS="$CLIENT_ROOT/android/key.properties"
if [[ ! -f "$KEY_PROPS" ]]; then
    fail "android/key.properties is missing.
Copy from android/key.properties.example and fill in real values.
Without it, the release build silently falls back to the debug key
and Play Console will reject the AAB."
fi
if ! grep -q "^storeFile=" "$KEY_PROPS"; then
    fail "android/key.properties has no storeFile= line."
fi
STORE_FILE=$(grep '^storeFile=' "$KEY_PROPS" | head -1 | cut -d= -f2- | xargs)
# Support both absolute and repo-relative storeFile paths.
if [[ "$STORE_FILE" != /* ]]; then
    STORE_FILE="$CLIENT_ROOT/android/$STORE_FILE"
fi
if [[ ! -f "$STORE_FILE" ]]; then
    fail "storeFile referenced by key.properties does not exist:
  $STORE_FILE
Point storeFile= at the absolute path of your upload keystore (.jks)."
fi
ok "key.properties + keystore present"

# --- 3. Clean --------------------------------------------------------
say "flutter clean…"
flutter clean >/dev/null
ok "clean done"

# --- 4. Deps ---------------------------------------------------------
say "flutter pub get…"
flutter pub get >/dev/null
ok "deps resolved"

# --- 5. Analyze ------------------------------------------------------
say "flutter analyze…"
if ! flutter analyze; then
    fail "analyze failed. Fix the reported issues before releasing."
fi
ok "analyze clean"

# --- 6. Tests --------------------------------------------------------
say "flutter test (full suite)…"
if ! flutter test; then
    fail "tests failed. Fix before releasing."
fi
ok "tests pass"

# --- 7. Build AAB ----------------------------------------------------
say "Building release AAB with:"
say "  API base:   $API_BASE"
say "  Share URL:  $SHARE_URL_BASE"
flutter build appbundle --release \
    --dart-define=NDUZEM_API_BASE="$API_BASE" \
    --dart-define=NDUZEM_SHARE_URL_BASE="$SHARE_URL_BASE"

AAB="$CLIENT_ROOT/build/app/outputs/bundle/release/app-release.aab"
if [[ ! -f "$AAB" ]]; then
    fail "build produced no AAB at $AAB"
fi
ok "AAB produced"

# --- 8. Verify AAB is release-signed (not the debug key) -------------
say "Verifying AAB signing key…"
if ! command -v keytool >/dev/null; then
    warn "keytool not on PATH — skipping signing verification.
Install a JDK to enable this check (e.g. via SDKMAN or your OS pkg manager)."
else
    CERT_OWNER=$(keytool -printcert -jarfile "$AAB" 2>/dev/null \
                 | grep -m1 '^Owner:' | sed 's/^Owner: //') || true
    if [[ -z "${CERT_OWNER:-}" ]]; then
        fail "Could not read signing certificate from AAB.
The AAB may be unsigned entirely — Gradle signing config may be broken."
    fi
    if echo "$CERT_OWNER" | grep -qi 'Android Debug'; then
        fail "AAB is signed with the DEBUG key ($CERT_OWNER).
Play Console will reject. Check that:
  1. android/key.properties exists (it does, we verified above)
  2. android/app/build.gradle.kts's release buildType references
     signingConfigs.getByName(\"release\") — NOT \"debug\"
Sometimes a stale build/ dir keeps a debug-signed artefact; the
'flutter clean' above should have addressed that. If this still
fires, try a full rebuild from a fresh clone."
    fi
    ok "signed by: $CERT_OWNER"
fi

# --- 9. Verify AD_ID absence in merged manifest ----------------------
# Locate the merged manifest that ships in the AAB. AGP has changed
# this path over versions; try the most likely locations and warn if
# nothing is found rather than fail (better to warn than block on a
# path guess).
say "Verifying merged manifest doesn't silently declare AD_ID…"
MANIFEST_CANDIDATES=(
    "$CLIENT_ROOT/build/app/intermediates/merged_manifests/release/AndroidManifest.xml"
    "$CLIENT_ROOT/build/app/intermediates/merged_manifest/release/AndroidManifest.xml"
    "$CLIENT_ROOT/build/app/intermediates/merged_manifests/release/processReleaseManifest/AndroidManifest.xml"
)
MERGED_MANIFEST=""
for candidate in "${MANIFEST_CANDIDATES[@]}"; do
    if [[ -f "$candidate" ]]; then
        MERGED_MANIFEST="$candidate"
        break
    fi
done
# Fallback: find any release-scoped merged manifest under build/.
if [[ -z "$MERGED_MANIFEST" ]]; then
    MERGED_MANIFEST=$(find "$CLIENT_ROOT/build" \
        -type f -name AndroidManifest.xml \
        -path '*release*' -path '*merged*' 2>/dev/null | head -1)
fi
if [[ -z "$MERGED_MANIFEST" || ! -f "$MERGED_MANIFEST" ]]; then
    warn "Could not locate the release merged manifest under build/.
AGP path layouts differ by version. To verify manually:
  unzip -p $AAB base/manifest/AndroidManifest.xml \\
    | strings | grep -c AD_ID
An answer of 0 means the AAB is clean; anything > 0 needs
tools:node=\"remove\" in AndroidManifest.xml (see docs/compliance/
on the server for the recipe)."
elif grep -q 'AD_ID' "$MERGED_MANIFEST"; then
    fail "AD_ID permission found in the merged manifest at
  $MERGED_MANIFEST
A transitive dep silently injected it. Options:
  1. Declare Yes on Play Console's advertising-ID gate, OR
  2. Add to android/app/src/main/AndroidManifest.xml (with
     xmlns:tools declared on <manifest>):
        <uses-permission
            android:name=\"com.google.android.gms.permission.AD_ID\"
            tools:node=\"remove\" />
     and re-run this script — the merged manifest should now be
     clean and Play Console can accept \"No\"."
else
    ok "no AD_ID declaration in merged manifest"
fi

# --- 10. Summary + next steps ----------------------------------------
AAB_SIZE=$(du -h "$AAB" | cut -f1)

# Pull versionName + versionCode from pubspec (flutter.versionName /
# versionCode wire straight through Gradle's defaultConfig).
VERSION_LINE=$(grep '^version:' pubspec.yaml || true)
VERSION_NAME=$(echo "$VERSION_LINE" | awk '{print $2}' | cut -d+ -f1)
VERSION_CODE=$(echo "$VERSION_LINE" | awk '{print $2}' | cut -d+ -f2)

CERT_SHA256=""
if command -v keytool >/dev/null; then
    CERT_SHA256=$(keytool -printcert -jarfile "$AAB" 2>/dev/null \
                  | grep -m1 'SHA256:' | sed 's/^.*SHA256: //') || true
fi

echo
printf '%s%s✓ Release AAB ready%s\n' "$C_BOLD" "$C_GREEN" "$C_RESET"
echo
printf '  Path:         %s\n' "$AAB"
printf '  Size:         %s\n' "$AAB_SIZE"
printf '  Version:      %s (build %s)\n' "$VERSION_NAME" "$VERSION_CODE"
printf '  API base:     %s\n' "$API_BASE"
printf '  Share URL:    %s\n' "$SHARE_URL_BASE"
[[ -n "${CERT_OWNER:-}" ]]  && printf '  Signed by:    %s\n' "$CERT_OWNER"
[[ -n "${CERT_SHA256:-}" ]] && printf '  SHA-256:      %s\n' "$CERT_SHA256"
echo
echo "Next steps:"
echo "  1. If the SHA-256 above changed since last release, update"
echo "     the fingerprint in the server repo's"
echo "     infra/www/.well-known/assetlinks.json and redeploy the"
echo "     marketing site. Android App Links won't verify otherwise."
echo "  2. Upload the AAB in Play Console → Testing → Internal"
echo "     testing → Create new release (or straight to Production"
echo "     once the store listing + review-credentials are filled)."
echo "  3. Bump versionCode in pubspec.yaml before the next release."
