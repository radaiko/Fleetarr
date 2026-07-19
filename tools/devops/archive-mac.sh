#!/usr/bin/env bash
# Build a signed macOS release archive and open it in Xcode Organizer for App Store Connect upload —
# without bumping the version (use ./ship.sh for a full release). Quit Xcode first (xcodegen runs).
#
# Note: distributing the Mac app via the App Store requires the App Sandbox capability (and the
# matching network-client / iCloud / Keychain entitlements). Fleetarr's macOS build is currently
# not sandboxed — add `com.apple.security.app-sandbox` to App/Fleetarr.entitlements before an App
# Store submission (Developer-ID / notarized direct distribution does not need it).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$REPO_ROOT"

regenerate_project
build="$(next_build_number)"
archive="$(build_macos_archive "$build")"
ok "macOS archive created (build $build): $archive"
info "Next: Organizer → Distribute App → App Store Connect → Upload."
[[ "${ORGANIZER_OPEN:-1}" == "1" ]] && open "$archive" || true
