#!/usr/bin/env bash
# Shared helpers for the Fleetarr devops scripts. Source, don't execute.
# Fleetarr is a single SwiftUI multiplatform target (iOS/iPadOS/macOS) generated from project.yml
# via xcodegen — no Rust core, no Android, unlike SnackPilot's variant of these scripts.
set -euo pipefail

# Absolute repo root, regardless of caller cwd.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

PROJECT_YML="$REPO_ROOT/project.yml"
XCODEPROJ="$REPO_ROOT/Fleetarr.xcodeproj"
SCHEME="Fleetarr"

# ── logging (all to stderr so stdout stays clean for captured values) ──
_c_red=$'\033[0;31m'; _c_grn=$'\033[0;32m'; _c_bld=$'\033[1m'; _c_off=$'\033[0m'
info() { printf '%s▸%s %s\n' "$_c_bld" "$_c_off" "$*" >&2; }
ok()   { printf '%s✓%s %s\n' "$_c_grn" "$_c_off" "$*" >&2; }
err()  { printf '%s✗%s %s\n' "$_c_red" "$_c_off" "$*" >&2; }
die()  { err "$*"; exit 1; }

have_tool()    { command -v "$1" >/dev/null 2>&1; }
require_tool() { have_tool "$1" || die "required tool '$1' not found on PATH${2:+ — $2}"; }

# ── version helpers ──
validate_semver() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

# version_gt A B → success iff A is strictly greater than B (semver via sort -V).
version_gt() {
  [[ "$1" != "$2" ]] || return 1
  [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" == "$1" ]]
}

verify_file_contains() { grep -qF -- "$2" "$1" || die "expected '$2' in $1 after edit — aborting"; }

# Edit `KEY: "value"` (yaml). Quotes preserved; the bump is verified to have landed.
set_yaml_key() {
  local file=$1 key=$2 val=$3
  sed -i '' -E "s/(${key}:[[:space:]]*\")[^\"]*(\")/\1${val}\2/" "$file"
  verify_file_contains "$file" "${key}: \"${val}\""
}

# Echo the Apple Team ID from the keychain signing identity (the cert's OU). Empty if none.
# FLEETARR_TEAM overrides; falls back to the project's known team so a fresh keychain still works.
detect_apple_team() {
  local ou
  ou="$(security find-certificate -c "Apple Development" -p 2>/dev/null \
    | openssl x509 -noout -subject -nameopt sep_multiline,utf8 2>/dev/null \
    | sed -n 's/^ *OU=//p' | head -1)"
  echo "${ou:-555V4MNLK3}"
}

resolve_team() { echo "${FLEETARR_TEAM:-$(detect_apple_team)}"; }

# Next monotonic build number: increment the gitignored counter and echo it, so every upload gets a
# unique, strictly-increasing CFBundleVersion (App Store Connect rejects duplicates).
next_build_number() {
  local f="$REPO_ROOT/tools/devops/.build-number" n=0
  [[ -f "$f" ]] && n="$(cat "$f")"
  n=$((n + 1))
  echo "$n" > "$f"
  echo "$n"
}

# Regenerate the .xcodeproj from project.yml so version bumps (and the Assets.xcassets app icon)
# land in the build. Safe to call repeatedly.
regenerate_project() {
  require_tool xcodegen "brew install xcodegen"
  if pgrep -x Xcode >/dev/null 2>&1; then
    err "Xcode is open — regenerating $XCODEPROJ underneath it can crash Xcode. Quit Xcode first."
    die "aborting to protect your Xcode session"
  fi
  ( cd "$REPO_ROOT" && xcodegen generate >&2 )
}

# _archive PLATFORM_LABEL DESTINATION BUILDNO [ARCHIVE_DIR] → archive a signed release build and
# echo the .xcarchive path (all logging on stderr). Assumes the project is already generated.
_archive() {
  local label=$1 destination=$2 buildno=$3
  local archdir="${4:-$HOME/Library/Developer/Xcode/Archives/$(date +%Y-%m-%d)}"
  require_tool xcodebuild "install Xcode"
  local team; team="$(resolve_team)"
  [[ -n "$team" ]] || die "no Apple team — set FLEETARR_TEAM=<teamid> (see: security find-identity -v -p codesigning)"
  mkdir -p "$archdir"
  local archive="$archdir/Fleetarr-$label $(date +%H.%M) build-$buildno.xcarchive"
  info "$label: archiving build $buildno (team $team)"
  xcodebuild -project "$XCODEPROJ" -scheme "$SCHEME" \
    -destination "$destination" \
    -archivePath "$archive" -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$team" CODE_SIGN_STYLE=Automatic CURRENT_PROJECT_VERSION="$buildno" \
    archive >&2
  echo "$archive"
}

build_ios_archive()   { _archive "iOS"   "generic/platform=iOS"   "$1" "${2:-}"; }
build_macos_archive() { _archive "macOS" "generic/platform=macOS" "$1" "${2:-}"; }
