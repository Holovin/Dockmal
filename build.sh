#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p .build/ModuleCache
app_path="${APP_OUTPUT_PATH:-$PWD/build/Dock Double Click.app}"
app_path="${app_path%/}"
app_name="$(basename "$app_path")"
if [[ "$app_name" != *.app ]]; then
    printf '%s\n' 'APP_OUTPUT_PATH must name an .app bundle.' >&2
    exit 1
fi
mkdir -p "$(dirname "$app_path")"
output_parent="$(cd "$(dirname "$app_path")" && pwd -P)"
app_path="$output_parent/$app_name"
if [[ -L "$app_path" || ( -e "$app_path" && ! -d "$app_path" ) ]]; then
    printf '%s\n' 'APP_OUTPUT_PATH must not be a symlink or a regular file.' >&2
    exit 1
fi

# Separate parents prevent an output name from colliding with the backup.
# Per-build test binaries also allow independent builds to run concurrently.
staging_dir="$(mktemp -d "$output_parent/.dock-double-click.XXXXXX")"
staged_app="$staging_dir/new/$app_name"
backup_app="$staging_dir/old/$app_name"
test_dir="$staging_dir/tests"
publish_lock="$app_path.build-lock"
publish_locked=false
cleanup() {
    local result=$?
    local retain_backup=false
    trap - EXIT
    trap '' INT TERM
    if [[ -d "$backup_app" && "$result" -ne 0 ]]; then
        if [[ ! -e "$app_path" && ! -L "$app_path" ]]; then
            if ! mv "$backup_app" "$app_path"; then retain_backup=true; fi
        else
            retain_backup=true
        fi
    fi
    if [[ "$retain_backup" == true ]]; then
        printf 'Previous app retained for recovery at %s\n' "$backup_app" >&2
    else
        rm -rf "$staging_dir"
    fi
    if [[ "$publish_locked" == true ]]; then rmdir "$publish_lock"; fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$staged_app/Contents/MacOS" "$staging_dir/old" "$test_dir"

xcrun swiftc -swift-version 5 -warnings-as-errors -module-cache-path "$PWD/.build/ModuleCache" \
    Sources/ClickGate.swift Tests/main.swift -o "$test_dir/click-gate-tests"
"$test_dir/click-gate-tests"

xcrun swiftc -swift-version 5 -warnings-as-errors -module-cache-path "$PWD/.build/ModuleCache" \
    Sources/OverlayHitPolicy.swift Tests/OverlayHitPolicyTests.swift -o "$test_dir/overlay-hit-tests"
"$test_dir/overlay-hit-tests"

xcrun swiftc -swift-version 5 -warnings-as-errors -module-cache-path "$PWD/.build/ModuleCache" \
    Sources/DockIconGeometry.swift Tests/DockIconGeometryTests.swift -o "$test_dir/dock-icon-geometry-tests"
"$test_dir/dock-icon-geometry-tests"

native_sources=(Sources/ClickGate.swift Sources/OverlayHitPolicy.swift Sources/DockIconGeometry.swift
                Sources/DockHighlight.swift Sources/DockHitTester.swift Sources/EventFilter.swift)
xcrun swiftc -swift-version 5 -warnings-as-errors -module-cache-path "$PWD/.build/ModuleCache" \
    -framework AppKit -framework ApplicationServices -framework QuartzCore \
    "${native_sources[@]}" Tests/EventFilterTests.swift -o "$test_dir/event-filter-tests"
"$test_dir/event-filter-tests"

xcrun swiftc -swift-version 5 -O -warnings-as-errors \
    -target arm64-apple-macosx13.0 -module-cache-path "$PWD/.build/ModuleCache" \
    -framework AppKit -framework ApplicationServices -framework ServiceManagement -framework QuartzCore \
    "${native_sources[@]}" Sources/main.swift -o "$staged_app/Contents/MacOS/DockDoubleClick"
cp Info.plist "$staged_app/Contents/Info.plist"
plutil -lint "$staged_app/Contents/Info.plist"

# A dash creates a complete ad-hoc bundle signature without a certificate.
codesign --force --sign "${SIGNING_IDENTITY:--}" --options runtime --timestamp=none "$staged_app"
codesign --verify --deep --strict --verbose=2 "$staged_app"

# Only publication is serialized. Never replace another build's output or lock.
if ! mkdir "$publish_lock" 2>/dev/null; then
    printf 'Could not acquire output lock: %s\n' "$publish_lock" >&2
    exit 1
fi
publish_locked=true
if [[ -L "$app_path" || ( -e "$app_path" && ! -d "$app_path" ) ]]; then
    printf '%s\n' 'Output changed during the build; refusing to replace it.' >&2
    exit 1
fi
if [[ -e "$app_path" ]]; then mv "$app_path" "$backup_app"; fi
# Using the parent prevents a competing destination from nesting our new bundle.
mv "$staged_app" "$output_parent/"
printf '%s\n' "$app_path"
