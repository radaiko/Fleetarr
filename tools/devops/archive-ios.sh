#!/usr/bin/env bash
# Build a signed iOS release archive and open it in Xcode Organizer for App Store Connect upload —
# without bumping the version (use ./ship.sh for a full release). Quit Xcode first (xcodegen runs).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$REPO_ROOT"

regenerate_project
build="$(next_build_number)"
archive="$(build_ios_archive "$build")"
ok "iOS archive created (build $build): $archive"
info "Next: Organizer → Distribute App → App Store Connect → Upload → TestFlight."
[[ "${ORGANIZER_OPEN:-1}" == "1" ]] && open "$archive" || true
