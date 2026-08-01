#!/usr/bin/env bash
#
# build-ios-release.sh — build a TestFlight/App-Store-ready OpaqueShare
# IPA with every pre- and post-flight check inline. iOS counterpart to
# build-release.sh (Android AAB) and build-web-release.sh.
#
# What it does, in order:
#   1. Verify we're on macOS with Flutter, Xcode, and CocoaPods.
#   2. Verify the iOS PLATFORM is installed — not just the SDK stub.
#      A fresh Xcode reports the SDK via `xcodebuild -showsdks` while
#      having no runtime, and every build then fails with the useless
#      "No Xcode build settings have been found."
#   3. Verify DEVELOPMENT_TEAM is set. Without it the archive step
#      fails deep inside xcodebuild with a signing error that doesn't
#      name the cause.
#   4. Verify Info.plist still declares ITSAppUsesNonExemptEncryption
#      and the entitlements still claim Associated Domains — the two
#      settings whose absence fails silently rather than loudly.
#   5. `flutter clean` / `pub get` / `analyze` / `test` — all must pass.
#   6. `flutter build ipa --release` with the API base threaded through
#      as --dart-define.
#   7. Crack the produced IPA open and verify what actually shipped:
#      bundle id, version + build number, export-compliance key, and
#      the associated-domains entitlement on the signed binary.
#   8. Print the IPA path, size, version, and the upload command.
#
# Exit 0 means the IPA under build/ios/ipa/ is ready to upload. Any
# non-zero exit is a hard failure with a message explaining what to fix.
#
# Usage:
#   scripts/build-ios-release.sh [OPAQUESHARE_API_BASE] [SHARE_URL_BASE]
#
# Or via env var:
#   OPAQUESHARE_API_BASE=https://api.opaqueshare.com scripts/build-ios-release.sh
#
# Optional env:
#   IOS_EXPORT_METHOD        app-store (default) | ad-hoc | development
#   IOS_EXPORT_OPTIONS_PLIST path to an ExportOptions.plist, overrides
#                            IOS_EXPORT_METHOD when set

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

# --- parse flags -----------------------------------------------------
# Delivery to Apple is opt-in. Building is safe and repeatable; sending
# a build to App Store Connect is neither, so it never happens as a side
# effect of asking for an IPA. Written for bash 3.2 (what macOS ships),
# hence no associative arrays and the `${arr[@]+...}` guard for the
# empty-array-under-set-u case.
DO_UPLOAD=0
DO_VALIDATE=0
POSITIONAL=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --upload)   DO_UPLOAD=1; shift ;;
        --validate) DO_VALIDATE=1; shift ;;
        -h|--help)
            sed -n '2,42p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        --*) fail "unknown flag: $1  (try --help)" ;;
        *)   POSITIONAL+=("$1"); shift ;;
    esac
done
set -- ${POSITIONAL[@]+"${POSITIONAL[@]}"}

# --upload implies validation: it's a few seconds and it converts most
# rejections from "an email twenty minutes later" into "an error now".
[[ "$DO_UPLOAD" -eq 1 ]] && DO_VALIDATE=1

# --- resolve arguments -----------------------------------------------
API_BASE="${1:-${OPAQUESHARE_API_BASE:-}}"
if [[ -z "$API_BASE" ]]; then
    fail "OPAQUESHARE_API_BASE is required.

Usage:
  scripts/build-ios-release.sh <API_BASE> [SHARE_URL_BASE] [--validate] [--upload]

Examples:
  # build only — the default, does not contact Apple
  scripts/build-ios-release.sh https://api.opaqueshare.com

  # build, then ask App Store Connect whether it would accept it
  scripts/build-ios-release.sh https://api.opaqueshare.com --validate

  # build, validate, then actually deliver to TestFlight/App Store
  ASC_KEY_ID=ABCD123456 ASC_ISSUER_ID=69a6de70-… \\
    scripts/build-ios-release.sh https://api.opaqueshare.com --upload"
fi

case "$API_BASE" in
    https://*) ;;
    http://*)  warn "API base is http:// — release builds should use https:// in production." ;;
    *)         fail "API base must be a full URL (starts with http:// or https://). Got: $API_BASE" ;;
esac

# Share URL base — where link-mode share URLs point. Falls back to
# stripping `api.` from the API host, matching AppConfig's own
# derivation and build-release.sh.
SHARE_URL_BASE="${2:-${OPAQUESHARE_SHARE_URL_BASE:-}}"
if [[ -z "$SHARE_URL_BASE" ]]; then
    # NOT `${API_BASE/\/\/api./\/\/}` — bash keeps the backslashes in the
    # replacement half of a pattern substitution, so that yields
    # `https:\/\/opaqueshare.com`, which then fails the validation below
    # with a baffling message. build-release.sh carried that bug too.
    SHARE_URL_BASE="$(printf '%s' "$API_BASE" | sed 's|//api\.|//|')"
    if [[ "$SHARE_URL_BASE" == "$API_BASE" ]]; then
        warn "Could not derive a share URL base from API base — no 'api.' prefix.
Falling back to the API base as the share host. Set
OPAQUESHARE_SHARE_URL_BASE explicitly if this is wrong for your setup."
    fi
fi

case "$SHARE_URL_BASE" in
    https://*|http://*) ;;
    *) fail "Share URL base must be a full URL. Got: $SHARE_URL_BASE" ;;
esac

EXPORT_METHOD="${IOS_EXPORT_METHOD:-app-store}"
EXPORT_PLIST="${IOS_EXPORT_OPTIONS_PLIST:-}"

# --- work from the client-repo root ----------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$CLIENT_ROOT"

# --- 1. Host + toolchain ---------------------------------------------
say "Checking host and toolchain…"
[[ "$(uname -s)" == "Darwin" ]] || fail "iOS builds require macOS. This is $(uname -s)."
command -v flutter >/dev/null || fail "flutter not on PATH."
command -v xcodebuild >/dev/null || fail "xcodebuild not on PATH. Install Xcode from the App Store."
command -v pod >/dev/null || fail "CocoaPods not on PATH.
flutter_secure_storage does not support Swift Package Manager, so
CocoaPods is still required. Install with: sudo gem install cocoapods"
# `|| true` is load-bearing under `set -o pipefail`. xcodebuild keeps
# writing after `head -1` exits, takes SIGPIPE, and pipefail turns that
# into a 141 that `set -e` acts on — the script would exit here, having
# printed the version and nothing else, with no error message at all.
flutter --version 2>/dev/null | head -1 || true
xcodebuild -version 2>/dev/null | head -1 || true
ok "toolchain ready"

# --- 2. iOS platform actually installed ------------------------------
# `xcodebuild -showsdks` lists the SDK even when the platform runtime
# was never downloaded. The only reliable probe is asking for a device
# destination and seeing whether one resolves.
say "Checking the iOS platform is installed (not just the SDK stub)…"
if ! xcodebuild -showsdks 2>/dev/null | grep -qi 'iOS'; then
    fail "No iOS SDK found. Open Xcode once to finish installation, then:
  xcodebuild -downloadPlatform iOS"
fi
# This probe takes ~30s: xcodebuild resolves the Swift Package graph
# before it will answer. Worth it — the failure it catches otherwise
# costs far longer to diagnose.
#
# Deliberately inspects the error text rather than just the exit code.
# On a fresh clone ios/Pods/ doesn't exist yet, so the workspace probe
# fails for a reason that has nothing to do with the platform, and
# treating any non-zero exit as "platform missing" would send you off
# to re-download several GB for no reason.
DEST_OUT=$(xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner \
             -destination 'generic/platform=iOS' -showBuildSettings 2>&1 || true)
if grep -qi 'is not installed' <<<"$DEST_OUT"; then
    fail "The iOS SDK is present but the PLATFORM is not installed, so no
build destination resolves. Flutter reports this as the misleading
'No Xcode build settings have been found.'

Fix (multi-GB, one time):
  xcodebuild -downloadPlatform iOS"
elif grep -q 'PRODUCT_BUNDLE_IDENTIFIER' <<<"$DEST_OUT"; then
    ok "iOS platform installed"
else
    warn "Couldn't confirm the iOS platform from xcodebuild — continuing.
Most likely ios/Pods/ isn't installed yet (fresh clone); the build
below runs 'pod install' and will surface any real problem. First
lines of xcodebuild output:
$(head -3 <<<"$DEST_OUT")"
fi

# --- 3. Signing team -------------------------------------------------
say "Checking release signing config…"
PBXPROJ="$CLIENT_ROOT/ios/Runner.xcodeproj/project.pbxproj"
[[ -f "$PBXPROJ" ]] || fail "missing $PBXPROJ"
if ! grep -q 'DEVELOPMENT_TEAM = [A-Z0-9]' "$PBXPROJ"; then
    fail "DEVELOPMENT_TEAM is not set in project.pbxproj.

Open ios/Runner.xcworkspace in Xcode, select the Runner target →
Signing & Capabilities → tick 'Automatically manage signing' → choose
your Team. Xcode writes the value into project.pbxproj.

Note: open the .xcworkspace, NOT the .xcodeproj — the Pods project is
only wired into the workspace."
fi
ok "DEVELOPMENT_TEAM set"

# --- 4. Settings that fail silently ----------------------------------
# Both of these produce a working build whose behaviour is quietly
# wrong, so they're worth asserting on every release rather than
# discovering from a rejected submission or a dead universal link.
say "Checking Info.plist + entitlements…"
INFO_PLIST="$CLIENT_ROOT/ios/Runner/Info.plist"
ENTITLEMENTS="$CLIENT_ROOT/ios/Runner/Runner.entitlements"

if ! /usr/libexec/PlistBuddy -c "Print :ITSAppUsesNonExemptEncryption" \
       "$INFO_PLIST" >/dev/null 2>&1; then
    fail "Info.plist has no ITSAppUsesNonExemptEncryption key.

Without it App Store Connect asks the export-compliance question on
EVERY submission and blocks processing until answered by hand. This
app's primary function is encryption, so the honest value is true —
see docs/adr/0015-ios-platform-parity.md."
fi
if ! /usr/libexec/PlistBuddy -c "Print :UIFileSharingEnabled" \
       "$INFO_PLIST" >/dev/null 2>&1; then
    warn "UIFileSharingEnabled is missing — received files will land in a
Documents directory the user cannot reach from the Files app."
fi
if [[ -f "$ENTITLEMENTS" ]]; then
    if ! grep -q 'com.apple.developer.associated-domains' "$ENTITLEMENTS"; then
        warn "Entitlements no longer claim associated-domains — universal links
(/r/, /password-reset, /verify-email) will open Safari instead of the app."
    fi
else
    warn "ios/Runner/Runner.entitlements is missing entirely."
fi
ok "Info.plist + entitlements look right"

# --- 4b. App Store Connect credentials (only when delivering) --------
# Checked HERE, before clean/analyze/test/build, so a missing key costs
# you a second rather than being discovered after a ten-minute build.
if [[ "$DO_VALIDATE" -eq 1 || "$DO_UPLOAD" -eq 1 ]]; then
    say "Checking App Store Connect credentials…"
    command -v xcrun >/dev/null || fail "xcrun not on PATH."

    [[ -n "${ASC_KEY_ID:-}" ]] || fail "ASC_KEY_ID is not set.

That's the 10-character Key ID from App Store Connect →
Users and Access → Integrations → App Store Connect API."

    [[ -n "${ASC_ISSUER_ID:-}" ]] || fail "ASC_ISSUER_ID is not set.

The Issuer ID is the UUID shown above the key list on the same page."

    # altool takes the KEY ID, not a path: it searches a fixed set of
    # directories for a file named exactly AuthKey_<KEY_ID>.p8. Renaming
    # the download breaks the lookup, and altool's own error for that is
    # opaque — so locate it here and say something useful.
    KEY_FILE="AuthKey_${ASC_KEY_ID}.p8"
    KEY_FOUND=""
    for d in "./private_keys" "$HOME/private_keys" "$HOME/.private_keys" \
             "$HOME/.appstoreconnect/private_keys" "${API_PRIVATE_KEYS_DIR:-}"; do
        [[ -n "$d" && -f "$d/$KEY_FILE" ]] && { KEY_FOUND="$d/$KEY_FILE"; break; }
    done
    if [[ -z "$KEY_FOUND" ]]; then
        fail "Couldn't find $KEY_FILE.

altool locates the key by NAME, not by path. Put it in one of:
  ./private_keys/            (inside the repo — avoid; it's gitignored
                              as a backstop, but keys don't belong here)
  ~/private_keys/
  ~/.private_keys/
  ~/.appstoreconnect/private_keys/     ← recommended
…or point API_PRIVATE_KEYS_DIR at the directory holding it.

The filename must be exactly $KEY_FILE — Apple's download is already
named that; renaming it breaks the lookup."
    fi
    case "$KEY_FOUND" in
        ./private_keys/*)
            warn "Using $KEY_FOUND — a private key inside the repo.
It's gitignored, but move it to ~/.appstoreconnect/private_keys/." ;;
    esac
    ok "credentials present (key $ASC_KEY_ID)"
fi

# --- 5. Version + build number ---------------------------------------
# App Store Connect rejects a build whose (version, build) pair has
# already been uploaded, and the rejection arrives minutes later by
# email rather than at upload time. Surface it up front.
APP_VERSION=$(grep '^version:' pubspec.yaml | head -1 | sed 's/^version:[[:space:]]*//')
say "pubspec version: ${C_BOLD}${APP_VERSION}${C_RESET}"
warn "If ${APP_VERSION##*+} was already uploaded for version ${APP_VERSION%%+*},
App Store Connect will reject this build. Bump the +N in pubspec.yaml first."

# --- 6. Clean --------------------------------------------------------
say "flutter clean…"
flutter clean >/dev/null
ok "clean done"

# --- 7. Deps ---------------------------------------------------------
say "flutter pub get…"
flutter pub get >/dev/null
ok "deps resolved"

# --- 8. Analyze ------------------------------------------------------
say "flutter analyze…"
if ! flutter analyze; then
    fail "analyze failed. Fix the reported issues before releasing."
fi
ok "analyze clean"

# --- 9. Tests --------------------------------------------------------
say "flutter test (full suite)…"
if ! flutter test; then
    fail "tests failed. Fix before releasing."
fi
ok "tests pass"

# --- 10. Build IPA ---------------------------------------------------
say "Building release IPA with:"
say "  API base:   $API_BASE"
say "  Share URL:  $SHARE_URL_BASE"
say "  Export:     ${EXPORT_PLIST:-$EXPORT_METHOD}"

BUILD_ARGS=(
    --release
    --dart-define=OPAQUESHARE_API_BASE="$API_BASE"
    --dart-define=OPAQUESHARE_SHARE_URL_BASE="$SHARE_URL_BASE"
)
if [[ -n "$EXPORT_PLIST" ]]; then
    [[ -f "$EXPORT_PLIST" ]] || fail "IOS_EXPORT_OPTIONS_PLIST does not exist: $EXPORT_PLIST"
    BUILD_ARGS+=(--export-options-plist "$EXPORT_PLIST")
else
    BUILD_ARGS+=(--export-method "$EXPORT_METHOD")
fi

flutter build ipa "${BUILD_ARGS[@]}"

IPA=$(find "$CLIENT_ROOT/build/ios/ipa" -maxdepth 1 -name '*.ipa' -print -quit 2>/dev/null || true)
[[ -n "$IPA" && -f "$IPA" ]] || fail "build produced no IPA under build/ios/ipa/"
ok "IPA produced"

# --- 11. Verify what actually shipped --------------------------------
# Everything above checks the SOURCE. This checks the artefact, which
# is what Apple will see. A stale build/ dir or a signing config that
# silently didn't apply shows up here and nowhere else.
say "Inspecting the built IPA…"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
unzip -q "$IPA" -d "$WORK"
APP=$(find "$WORK/Payload" -maxdepth 1 -name '*.app' -print -quit)
[[ -n "$APP" ]] || fail "no .app inside the IPA payload"

plist_get() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Info.plist" 2>/dev/null || echo ""; }

SHIPPED_ID=$(plist_get CFBundleIdentifier)
SHIPPED_VER=$(plist_get CFBundleShortVersionString)
SHIPPED_BUILD=$(plist_get CFBundleVersion)
SHIPPED_ENC=$(plist_get ITSAppUsesNonExemptEncryption)
SHIPPED_MIN=$(plist_get MinimumOSVersion)

[[ -n "$SHIPPED_ID" ]] || fail "built app has no CFBundleIdentifier"
[[ "$SHIPPED_ENC" == "true" || "$SHIPPED_ENC" == "false" ]] \
    || fail "ITSAppUsesNonExemptEncryption did not make it into the built app."

if command -v codesign >/dev/null; then
    ENTS=$(codesign -d --entitlements :- "$APP" 2>/dev/null || true)
    if echo "$ENTS" | grep -q 'associated-domains'; then
        ok "signed binary carries the associated-domains entitlement"
    else
        warn "The signed binary does NOT carry associated-domains.

Universal links will silently fall back to Safari. Usual cause: the
App ID in the developer portal doesn't have the Associated Domains
capability enabled, so the profile Xcode generated omits it."
    fi
    if echo "$ENTS" | grep -q '<key>get-task-allow</key>' && \
       echo "$ENTS" | grep -A1 'get-task-allow' | grep -q '<true/>'; then
        fail "get-task-allow is TRUE — this is a debug-signed build.
App Store Connect will reject it. Something exported with a
development profile instead of distribution."
    fi
fi

IPA_SIZE=$(du -h "$IPA" | cut -f1 | tr -d ' ')

printf '\n%s─────────────────────────────────────────────%s\n' "$C_BOLD" "$C_RESET"
ok "iOS release build complete"
printf '  IPA:        %s\n' "$IPA"
printf '  Size:       %s\n' "$IPA_SIZE"
printf '  Bundle id:  %s\n' "$SHIPPED_ID"
printf '  Version:    %s (build %s)\n' "$SHIPPED_VER" "$SHIPPED_BUILD"
printf '  Min iOS:    %s\n' "$SHIPPED_MIN"
printf '  Encryption: ITSAppUsesNonExemptEncryption=%s\n' "$SHIPPED_ENC"
printf '%s─────────────────────────────────────────────%s\n\n' "$C_BOLD" "$C_RESET"

# --- 12. Validate / upload (opt-in) ----------------------------------
if [[ "$DO_VALIDATE" -eq 1 ]]; then
    say "Validating with App Store Connect (no delivery)…"
    if xcrun altool --validate-app -f "$IPA" -t ios \
         --api-key "$ASC_KEY_ID" --api-issuer "$ASC_ISSUER_ID"; then
        ok "App Store Connect would accept this build"
    else
        fail "Validation failed — see the error above. Nothing was delivered.

Common first-time causes:
  • No app record in App Store Connect for $SHIPPED_ID
  • Build $SHIPPED_BUILD already used for version $SHIPPED_VER
  • Missing export-compliance answer on the app record"
    fi
fi

if [[ "$DO_UPLOAD" -eq 1 ]]; then
    say "Uploading to App Store Connect…"
    if xcrun altool --upload-app -f "$IPA" -t ios \
         --api-key "$ASC_KEY_ID" --api-issuer "$ASC_ISSUER_ID"; then
        ok "uploaded — processing takes a few minutes before it appears in TestFlight"
    else
        fail "Upload failed — see the error above."
    fi
else
    printf '\n'
    say "Not uploaded (pass --upload to deliver, --validate to dry-run)."
fi

cat <<EOF

Notes:

  1. The app record must already exist in App Store Connect
     (My Apps → + → New App, bundle id $SHIPPED_ID). Uploading
     without it succeeds and then the build never appears.

  2. Manual upload, if you'd rather not use --upload:
       xcrun altool --upload-app -f "$IPA" -t ios \\
         --api-key <KEY_ID> --api-issuer <ISSUER_ID>

     --api-key takes the 10-character Key ID, NOT a file path. The
     key itself is found by name — AuthKey_<KEY_ID>.p8 — in
     ~/.appstoreconnect/private_keys/ (or one of altool's other
     search dirs). Or drag the IPA into Transporter.app.

  3. Export compliance: this build declares it uses non-exempt
     encryption. Before the first submission, file a year-end
     self-classification report with BIS (ECCN 5D992.c). Asked once
     per app, not per build — see docs/dev/ios-platform-setup.md.

  4. In-app purchase does NOT work on iOS yet. iap_purchase_service.dart
     returns early unless Platform.isAndroid, and the server's
     AppleReceiptVerifier is stub-only, so a TestFlight tester cannot
     complete a purchase. Android is the only place billing works today.
EOF
