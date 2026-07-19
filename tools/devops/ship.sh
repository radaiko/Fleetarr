#!/usr/bin/env bash
# Cut a release: bump the version, archive signed iOS and/or macOS builds, and open each in Xcode
# Organizer so you can upload to App Store Connect (Distribute App → App Store Connect → Upload).
# Then commit the version bump and tag it locally.
#
#   ./tools/devops/ship.sh            # interactive
#   DRY_RUN=1 ./tools/devops/ship.sh  # build artifacts, touch no files/commits/tags/counters
#
# Note: Quit Xcode before running — the project is regenerated from project.yml (xcodegen), which
# can crash an open Xcode. macOS App Store builds also require the app sandbox; see README notes.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$REPO_ROOT"

DRY_RUN="${DRY_RUN:-0}"
HISTORY="$REPO_ROOT/.ship-history"
BUILDNO_FILE="$REPO_ROOT/tools/devops/.build-number"

# Revert the project.yml bump if we fail after editing it but before the commit lands.
bumped=0; committed=0
cleanup() {
  local rc=$?
  if [[ "$bumped" == "1" && "$committed" == "0" ]]; then
    err "ship failed (exit $rc) — reverting the project.yml version bump"
    git checkout -- "$PROJECT_YML" 2>/dev/null || true
  fi
  exit $rc
}
trap cleanup EXIT

[[ "$DRY_RUN" == "1" ]] && info "DRY RUN — no files, commits, tags, or counters will change"

# 1. version
last="0.0.0"; [[ -f "$HISTORY" ]] && last="$(tail -1 "$HISTORY")"
info "last shipped version: $last"
read -rp "New version (strict semver, > $last): " VERSION
validate_semver "$VERSION" || die "invalid version '$VERSION' — must be X.Y.Z"
version_gt "$VERSION" "$last" || die "$VERSION must be strictly greater than $last"

# 2. platforms
echo "Platforms:  1) iOS   2) macOS   3) both" >&2
read -rp "Select (e.g. 1,2 or 3): " sel
do_ios=0; do_mac=0
[[ "$sel" == *1* || "$sel" == *3* ]] && do_ios=1
[[ "$sel" == *2* || "$sel" == *3* ]] && do_mac=1
[[ $do_ios -eq 1 || $do_mac -eq 1 ]] || die "no platform selected"
label=""; [[ $do_ios -eq 1 ]] && label="ios"; [[ $do_mac -eq 1 ]] && label="${label:+$label,}macos"
info "shipping v$VERSION ($label)"

# Fail fast if a target tag already exists, so a collision can't orphan a Release commit later.
for _plat in ${label//,/ }; do
  git rev-parse -q --verify "refs/tags/$_plat/v$VERSION" >/dev/null 2>&1 \
    && die "tag $_plat/v$VERSION already exists — bump the version or delete the tag first"
done

# 3. build number (increment; dry-run just previews)
buildno=0; [[ -f "$BUILDNO_FILE" ]] && buildno="$(cat "$BUILDNO_FILE")"
buildno=$((buildno + 1))
info "build number: $buildno"

# 4. bump project.yml (skip on dry-run) + regenerate the Xcode project
if [[ "$DRY_RUN" != "1" ]]; then
  set_yaml_key "$PROJECT_YML" MARKETING_VERSION "$VERSION"
  set_yaml_key "$PROJECT_YML" CURRENT_PROJECT_VERSION "$buildno"
  bumped=1
  ok "bumped project.yml to $VERSION (build $buildno)"
else
  info "(dry-run) would bump project.yml to $VERSION / build $buildno"
fi
regenerate_project

# 5. archive selected platforms
archives=()
if [[ $do_ios -eq 1 ]]; then
  archive="$(build_ios_archive "$buildno")"
  ok "iOS archive: $archive"
  archives+=("$archive")
fi
if [[ $do_mac -eq 1 ]]; then
  archive="$(build_macos_archive "$buildno")"
  ok "macOS archive: $archive"
  archives+=("$archive")
fi

# 6. commit + tag + history (skip on dry-run)
if [[ "$DRY_RUN" == "1" ]]; then
  ok "DRY RUN complete — archives built; no git or counter changes made"
  exit 0
fi
echo "$buildno" > "$BUILDNO_FILE"
git add "$PROJECT_YML"
git commit -m "Release v$VERSION ($label)"
committed=1
[[ $do_ios -eq 1 ]] && git tag "ios/v$VERSION"
[[ $do_mac -eq 1 ]] && git tag "macos/v$VERSION"
echo "$VERSION" >> "$HISTORY"
ok "committed Release v$VERSION ($label) and tagged locally"

# 7. hand off to Organizer for the upload
info "opening Xcode Organizer — for each: Distribute App → App Store Connect → Upload"
for a in "${archives[@]}"; do open "$a"; done
info "to publish the tags later: git push && git push --tags"
