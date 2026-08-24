#!/usr/bin/env bash
#
# build-web-release.sh — build the Flutter web bundle ready to rsync
# to prod. Web mirror of build-release.sh (which produces the Android
# AAB). Fewer post-flight checks because the web bundle isn't signed
# and there's no store review to trip.
#
# What it does, in order:
#   1. Verify Flutter is on PATH.
#   2. `flutter clean` — drop stale build artefacts.
#   3. `flutter pub get` — fetch deps.
#   4. `flutter analyze` — must be clean.
#   5. `flutter test` — full suite must pass.
#   6. `flutter build web --release` with the API + share dart-defines.
#   7. Verify `build/web/index.html` came out.
#   8. Print bundle path, size, entrypoint hash, and next steps
#      (rsync target + Caddy reload if the vhost is new).
#
# Exit code 0 means `client/build/web/` is ready to rsync. Any
# non-zero exit is a hard failure with a message on stderr.
#
# Usage:
#   scripts/build-web-release.sh [NDUZEM_API_BASE] [NDUZEM_SHARE_URL_BASE]
#
# Or via env var:
#   NDUZEM_API_BASE=https://api.nduzem.com scripts/build-web-release.sh
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
  scripts/build-web-release.sh https://api.nduzem.com [https://nduzem.com]

Or:
  export NDUZEM_API_BASE=https://api.nduzem.com
  scripts/build-web-release.sh"
fi

case "$API_BASE" in
    https://*) ;;
    http://*)  warn "API base is http:// — release builds should use https:// in production." ;;
    *)         fail "API base must be a full URL (starts with http:// or https://). Got: $API_BASE" ;;
esac

# Share URL base — same derivation as build-release.sh so the two
# scripts stay in lockstep on how they compute defaults.
SHARE_URL_BASE="${2:-${NDUZEM_SHARE_URL_BASE:-}}"
if [[ -z "$SHARE_URL_BASE" ]]; then
    # Derive by stripping a leading `api.` from the URL's host.
    #
    # Was `${API_BASE/\/\/api./\/\/}`, which is broken: bash keeps the
    # backslashes in the replacement half of a pattern substitution, so
    # it produced `https:\/\/nduzem.com` and then tripped the validation
    # below with a message that blamed the input. It failed safe rather
    # than baking a malformed URL into a release, but it meant the
    # documented one-argument invocation always failed for the normal
    # `api.<host>` deployment.
    #
    # The Android and iOS scripts were fixed and this one was not — the
    # three derive the same value and must stay in lockstep.
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

# --- 2. Clean --------------------------------------------------------
say "flutter clean…"
flutter clean >/dev/null
ok "clean done"

# --- 3. Deps ---------------------------------------------------------
say "flutter pub get…"
flutter pub get >/dev/null
ok "deps resolved"

# --- 4. Analyze ------------------------------------------------------
say "flutter analyze…"
if ! flutter analyze; then
    fail "analyze failed. Fix the reported issues before releasing."
fi
ok "analyze clean"

# --- 5. Tests --------------------------------------------------------
say "flutter test (full suite)…"
if ! flutter test; then
    fail "tests failed. Fix before releasing."
fi
ok "tests pass"

# --- 6. Build web bundle ---------------------------------------------
say "Building release web bundle with:"
say "  API base:   $API_BASE"
say "  Share URL:  $SHARE_URL_BASE"
# --no-web-resources-cdn is NOT optional here.
#
# By default Flutter loads CanvasKit from www.gstatic.com and the Roboto
# font from fonts.gstatic.com AT RUNTIME. For this product that is three
# problems at once: third-party JavaScript with full DOM access on the
# origin that holds the user's identity private key; an IP + timing leak
# to Google on every app load, from a tool sold on not leaking; and a
# runtime dependency that makes the shipped app not self-contained,
# which undercuts the reproducible-build claim in spec §13.1.
#
# The bundle already ships a local canvaskit/ directory — it was simply
# going unused. This flag makes the app load it, and with it the app
# issues zero off-origin requests.
#
# The deployed Content-Security-Policy (infra/docker/Caddyfile, app.
# vhost) has no CDN origin in `script-src`/`connect-src`, so dropping
# this flag does not quietly reintroduce the dependency — it breaks the
# app at load time, visibly, on the next deploy.
flutter build web --release \
    --no-web-resources-cdn \
    --dart-define=NDUZEM_API_BASE="$API_BASE" \
    --dart-define=NDUZEM_SHARE_URL_BASE="$SHARE_URL_BASE"

BUNDLE_DIR="$CLIENT_ROOT/build/web"
if [[ ! -f "$BUNDLE_DIR/index.html" ]]; then
    fail "build produced no bundle at $BUNDLE_DIR (missing index.html)"
fi
ok "bundle produced"

# --- 6b. Refuse a bundle that phones home ----------------------------
#
# The CDN dependency is invisible in the output of a successful build,
# so verify it rather than trusting the flag above survived an edit.
# `useLocalCanvasKit` is what the Flutter loader actually branches on;
# the gstatic URL remains in the bundle as the unused else-branch, so
# grepping for the URL alone would false-positive forever.
if ! grep -q 'useLocalCanvasKit"*:*"*true' "$BUNDLE_DIR/flutter_bootstrap.js" 2>/dev/null; then
    fail "bundle is configured to load CanvasKit from www.gstatic.com.
       The --no-web-resources-cdn flag did not take effect. Shipping
       this would put third-party JavaScript on the origin that holds
       users' identity private keys, and the deployed CSP would block
       the app on arrival."
fi
ok "self-contained (CanvasKit served locally, no CDN at runtime)"

# --- 7. Summary + next steps -----------------------------------------
BUNDLE_SIZE=$(du -sh "$BUNDLE_DIR" | cut -f1)
FILE_COUNT=$(find "$BUNDLE_DIR" -type f | wc -l | tr -d ' ')

# Grab the hashed main.dart.js name — different every build, useful
# in the summary as a quick "is this actually a fresh build?" tell.
MAIN_JS=$(find "$BUNDLE_DIR" -maxdepth 1 -name 'main.dart.js*' -not -name '*.map' 2>/dev/null \
          | head -1 | xargs -I{} basename {})

echo
printf '%s%s✓ Web bundle ready%s\n' "$C_BOLD" "$C_GREEN" "$C_RESET"
echo
printf '  Path:         %s\n' "$BUNDLE_DIR"
printf '  Size:         %s (%s files)\n' "$BUNDLE_SIZE" "$FILE_COUNT"
printf '  API base:     %s\n' "$API_BASE"
printf '  Share URL:    %s\n' "$SHARE_URL_BASE"
[[ -n "$MAIN_JS" ]] && printf '  Entrypoint:   %s\n' "$MAIN_JS"
echo
echo "Next steps:"
echo "  1. rsync the bundle to the prod box (adjust host + path):"
echo "     rsync -av --delete build/web/ prod:/opt/opaqueshare-server/infra/www-app/"
echo "  2. Caddy serves the new files immediately (bind-mount, live)."
echo "     If the app.\$DOMAIN vhost is new, reload Caddy once:"
echo "       docker compose -f infra/docker/docker-compose.prod.yml \\"
echo "         exec caddy caddy reload --config /etc/caddy/Caddyfile"
echo "  3. Verify:"
echo "       curl -sI https://app.\$DOMAIN | head -1"
echo "     Expect HTTP/2 200. Cert provisions on first request via ACME."
