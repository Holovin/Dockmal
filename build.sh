#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p .build/ModuleCache
app_path="${APP_OUTPUT_PATH:-$PWD/build/Dockmal.app}"
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

# Keep staging on the output filesystem for atomic rename/swap.
staging_dir="$(mktemp -d "$output_parent/.dockmal.XXXXXX")"
staged_app="$staging_dir/new/$app_name"
test_dir="$staging_dir/tests"
cleanup() {
    local result=$?
    trap - EXIT
    trap '' INT TERM
    rm -rf "$staging_dir"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$staged_app/Contents/MacOS" "$test_dir"

xcrun clang -Wall -Wextra -Werror Tools/publish.c -o "$test_dir/publish"
# Detect a busy or legacy lock before compiling the app; replacement locks again.
"$test_dir/publish" check "$app_path"

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
    "${native_sources[@]}" Sources/main.swift -o "$staged_app/Contents/MacOS/Dockmal"
cp Info.plist "$staged_app/Contents/Info.plist"
plutil -lint "$staged_app/Contents/Info.plist"

# A dash creates a complete ad-hoc bundle signature without a certificate.
codesign --force --sign "${SIGNING_IDENTITY:--}" --options runtime --timestamp=none "$staged_app"
codesign --verify --deep --strict --verbose=2 "$staged_app"

# A successful swap leaves the old app at staged_app for cleanup. If killed
# before or after the swap, output still names a complete signed bundle.
"$test_dir/publish" replace "$staged_app" "$app_path"
printf '%s\n' "$app_path"
