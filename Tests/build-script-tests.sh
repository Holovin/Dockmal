#!/bin/bash
# Packaging regressions only: no compiler, real signing, app launch, or input hooks.
set -euo pipefail
shopt -s nullglob
repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/dock-double-click-build-tests.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
fake_bin="$test_root/bin"
mkdir -p "$fake_bin"

cat > "$fake_bin/xcrun" <<'FAKE'
#!/bin/bash
set -euo pipefail
output=
while [[ "$#" -gt 0 ]]; do
    if [[ "$1" == -o ]]; then output="$2"; break; fi
    shift
done
[[ -n "$output" ]] || exit 90
if [[ "${FAKE_BUILD_FAILURE:-}" == compile && "$output" == */Contents/MacOS/Dockmal ]]; then
    exit 71
fi
mkdir -p "$(dirname "$output")"
printf '#!/bin/bash\nexit 0\n' > "$output"
chmod +x "$output"
FAKE
cat > "$fake_bin/plutil" <<'FAKE'
#!/bin/bash
set -euo pipefail
[[ "$1" == -lint && -s "$2" ]]
FAKE
cat > "$fake_bin/codesign" <<'FAKE'
#!/bin/bash
set -euo pipefail
bundle="${!#}"
if [[ "$1" == --verify ]]; then
    [[ "${FAKE_BUILD_FAILURE:-}" != verify ]] || exit 73
    [[ -x "$bundle/Contents/MacOS/Dockmal" ]]
    [[ "$(cat "$bundle/Contents/_CodeSignature/CodeResources")" == fresh-signature ]]
else
    [[ "${FAKE_BUILD_FAILURE:-}" != sign ]] || exit 72
    mkdir -p "$bundle/Contents/_CodeSignature"
    printf '%s\n' fresh-signature > "$bundle/Contents/_CodeSignature/CodeResources"
fi
FAKE
chmod +x "$fake_bin/xcrun" "$fake_bin/plutil" "$fake_bin/codesign"

cases=0
new_case() {
    case_name="$1"
    case_dir="$test_root/$case_name"
    mkdir -p "$case_dir/out"
    cp "$repo_root/build.sh" "$case_dir/build.sh"
    printf '%s\n' '<plist version="1.0"><dict/></plist>' > "$case_dir/Info.plist"
    output_parent="$case_dir/out"
    output="$output_parent/previous.app"
    log="$case_dir/build.log"
}
fail() {
    printf 'FAIL %s: %s\n' "$case_name" "$1" >&2
    if [[ -f "$log" ]]; then cat "$log" >&2; fi
    exit 1
}
check() {
    local message="$1"
    shift
    if ! "$@"; then fail "$message"; fi
}
run_build() {
    env PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        APP_OUTPUT_PATH="$output" SIGNING_IDENTITY= FAKE_BUILD_FAILURE="${1:-}" \
        /bin/bash "$case_dir/build.sh" > "$log" 2>&1
}
seed_old_bundle() {
    mkdir -p "$output/Contents/MacOS" "$output/Contents/_CodeSignature"
    printf '%s\n' old-executable > "$output/Contents/MacOS/Dockmal"
    printf '%s\n' old-resource > "$output/old-only-resource"
    printf '%s\n' stale-signature > "$output/Contents/_CodeSignature/stale-marker"
    cp -R "$output" "$case_dir/expected-old.app"
}
check_no_staging() {
    local staging=("$output_parent"/.dock-double-click.*)
    check 'staging directories must be cleaned' test "${#staging[@]}" -eq 0
}
check_no_lock() {
    check 'owned publication lock must be released' test ! -e "$output.build-lock"
}
pass() {
    cases=$((cases + 1))
    printf 'PASS %s\n' "$case_name"
}

new_case successful_rebuild_of_previous_app
seed_old_bundle
if ! run_build; then fail 'build should succeed'; fi
check 'new executable must replace old executable' test -x "$output/Contents/MacOS/Dockmal"
check 'old resources must not survive' test ! -e "$output/old-only-resource"
check 'old signature contents must not survive' test ! -e "$output/Contents/_CodeSignature/stale-marker"
check 'fresh signature must be published' test "$(cat "$output/Contents/_CodeSignature/CodeResources")" = fresh-signature
check 'old bundle must not be nested in the new bundle' test ! -e "$output/previous.app"
check_no_staging
check_no_lock
pass

for failure in compile sign verify; do
    for existing in present absent; do
        new_case "${failure}_failure_with_${existing}_output"
        if [[ "$existing" == present ]]; then seed_old_bundle; fi
        if run_build "$failure"; then fail 'injected failure should reject build'; fi
        if [[ "$existing" == present ]]; then
            check 'failed build must preserve every old file' diff -rq "$case_dir/expected-old.app" "$output"
        else
            check 'failed build must not publish an incomplete app' test ! -e "$output"
        fi
        check_no_staging
        check_no_lock
        pass
    done
done

new_case output_symlink_is_rejected
mkdir -p "$case_dir/linked-target.app"
printf '%s\n' preserve-me > "$case_dir/linked-target.app/sentinel"
cp -R "$case_dir/linked-target.app" "$case_dir/expected-target.app"
ln -s "$case_dir/linked-target.app" "$output"
if run_build; then fail 'symlink output should be rejected'; fi
check 'output symlink must remain intact' test -L "$output"
check 'symlink target must remain intact' diff -rq "$case_dir/expected-target.app" "$case_dir/linked-target.app"
check_no_staging
check_no_lock
pass

new_case occupied_publication_lock_is_preserved
seed_old_bundle
mkdir "$output.build-lock"
printf '%s\n' another-build > "$output.build-lock/owner"
cp -R "$output.build-lock" "$case_dir/expected-lock"
if run_build; then fail 'existing publication lock should reject build'; fi
check 'contended build must preserve old output' diff -rq "$case_dir/expected-old.app" "$output"
check 'another build lock must remain untouched' diff -rq "$case_dir/expected-lock" "$output.build-lock"
check_no_staging
pass

printf '%s packaging cases passed; real compiler and codesign were not invoked.\n' "$cases"
