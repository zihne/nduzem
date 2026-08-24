#!/usr/bin/env bash
#
# Reproducible-build verification — NOT YET IMPLEMENTED.
#
# This script exits NON-ZERO on purpose.
#
# It previously contained only a TODO comment and therefore exited 0:
# running it printed nothing and reported success, which is
# indistinguishable from having verified the release. That is worse than
# having no script at all — a silent pass invites someone to believe a
# build was checked when nothing was compared.
#
# Until the real implementation lands, failing loudly is the honest
# behaviour. Any CI step or release checklist that shells out to this
# will now stop, which is the intent: reproducible-build verification is
# a stated blocker for the "verifiable beta" milestone, and a blocker
# that passes silently is not a blocker.
#
# TODO: rebuild from pinned source in a hermetic container and compare
# the binary hash to the published manifest for <release-tag>.
set -euo pipefail

cat >&2 <<'EOF'
verify.sh: NOT IMPLEMENTED — nothing was verified.

Reproducible-build verification is still under construction. This script
exits non-zero so that a release process cannot mistake "ran without
error" for "build verified".

What it will do, once implemented:
  1. Resolve <release-tag> to a source commit and build manifest.
  2. Rebuild in a hermetic container from that pinned source.
  3. Compare the resulting binary hash against the manifest.
  4. Exit 0 only on an exact match.

Until then the "zero-knowledge" claim rests on the published design and
the source, not on a reproduced binary. See README.md § Verifying a
release, and provability/audit/.
EOF

exit 2
