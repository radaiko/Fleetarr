.PHONY: ship ios-archive mac-archive ship-dry generate

# Full release: bump version, archive iOS/macOS, open Organizer for App Store Connect upload.
ship:
	@./tools/devops/ship.sh

# Same, but build artifacts only — no file/commit/tag/counter changes.
ship-dry:
	@DRY_RUN=1 ./tools/devops/ship.sh

# Single-platform archives (no version bump).
ios-archive:
	@./tools/devops/archive-ios.sh

mac-archive:
	@./tools/devops/archive-mac.sh

# Regenerate Fleetarr.xcodeproj from project.yml (quit Xcode first).
generate:
	@xcodegen generate
