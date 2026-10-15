# shellcheck shell=bash
#
# Resolve the Flutter SDK the build must use, and refuse to proceed with
# any other one. Sourced by the three build-*.sh scripts.
#
# WHY THIS EXISTS. A bare `flutter` resolves to whatever is on PATH,
# which on a machine with more than one project is whatever the last
# project needed. `~/flutter` is a single git clone: switching it for
# one project silently repoints every other. That is not hypothetical —
# it happened, and `flutter pub get` failed with "Try using the Flutter
# SDK version: 3.47.7", which reads like a dependency problem and was
# actually the Dart SDK being too old.
#
# For a release build that is worse than an inconvenience. The whole
# claim of `provability/reproducible-build/` is that a published binary
# can be tied to a source commit, and a binary built with an unrecorded
# SDK cannot be. So this does not pick a working Flutter; it insists on
# the pinned one and stops otherwise.
#
# Sets, for the caller to use:
#   FLUTTER        — array; invoke as "${FLUTTER[@]}" build …
#   FLUTTER_PINNED — version string from .fvmrc
#   FLUTTER_FULL   — full `flutter --version` output, for the manifest
#
# Requires CLIENT_ROOT, and `fail`/`ok`/`say` from the calling script.

_fvmrc="$CLIENT_ROOT/.fvmrc"
[[ -f "$_fvmrc" ]] || fail "$_fvmrc is missing.
It pins the Flutter version this project builds with. Restore it from
git, or recreate it with: fvm use <version>"

FLUTTER_PINNED="$(python3 -c "
import json, sys
print(json.load(open('$_fvmrc'))['flutter'])
" 2>/dev/null)" || fail "could not read a version out of $_fvmrc"
[[ -n "$FLUTTER_PINNED" ]] || fail "$_fvmrc names no Flutter version."

# Prefer the SDK fvm has already materialised for this project: an
# absolute path works whether or not fvm is on PATH, and whether or not
# the caller remembered to prefix the command.
if [[ -x "$CLIENT_ROOT/.fvm/flutter_sdk/bin/flutter" ]]; then
    FLUTTER=("$CLIENT_ROOT/.fvm/flutter_sdk/bin/flutter")
elif command -v fvm >/dev/null; then
    FLUTTER=(fvm flutter)
elif command -v flutter >/dev/null; then
    FLUTTER=(flutter)
else
    fail "No Flutter SDK found.
This project pins Flutter $FLUTTER_PINNED in .fvmrc. Install it with:
  brew tap leoafarias/fvm && brew install fvm
  cd $CLIENT_ROOT && fvm install"
fi

# Capture the whole stream before slicing it. `flutter --version | head -1`
# looks harmless but breaks intermittently: head exits after one line, and
# when flutter then tries to print its "a new version is available" box the
# closed pipe raises SIGPIPE, which the Dart tool does not handle — it dies
# with an unhandled FileSystemException and takes the build with it. The
# failure only appears when flutter happens to have an upgrade notice, so it
# looks random and unrelated to whatever else changed.
FLUTTER_FULL="$("${FLUTTER[@]}" --version 2>/dev/null)"
_first_line="${FLUTTER_FULL%%$'\n'*}"
# "Flutter 3.47.0-0.2.pre • channel beta • https://…"
_actual="$(printf '%s\n' "$_first_line" | awk '{print $2}')"

if [[ "$_actual" != "$FLUTTER_PINNED" ]]; then
    fail "Flutter version mismatch.

  .fvmrc pins : $FLUTTER_PINNED
  this SDK is : ${_actual:-unknown}
  resolved to : ${FLUTTER[*]}

A release built with an unpinned SDK cannot be tied to its source, which
is the one thing the build manifest is for. Either install the pinned
version:

  cd $CLIENT_ROOT && fvm install && fvm use $FLUTTER_PINNED

or, if you genuinely mean to move the project, change .fvmrc and the
flutter-version in .github/workflows/client-ci.yml together — CI fails
if they disagree."
fi

printf '%s\n' "$_first_line"
unset _fvmrc _first_line _actual
