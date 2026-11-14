#!/bin/bash
# Packaging regressions: real filesystem publisher, mocked Swift app and signing.
set -euo pipefail
shopt -s nullglob
repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/dockmal-build-tests.XXXXXX")"
publisher_pid=
build_pid=
cleanup() {
    if [[ -n "$publisher_pid" ]]; then kill -KILL "$publisher_pid" 2>/dev/null || true; fi
    if [[ -n "$build_pid" ]]; then
        kill -TERM "$build_pid" 2>/dev/null || true
        wait "$build_pid" 2>/dev/null || true
    fi
    rm -rf "$test_root"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
fake_bin="$test_root/bin"
mkdir -p "$fake_bin"
xcrun clang -Wall -Wextra -Werror -DDOCKMAL_PUBLICATION_TESTING \
    "$repo_root/Tools/publish.c" -o "$test_root/publish"

cat > "$fake_bin/xcrun" <<'FAKE'
#!/bin/bash
set -euo pipefail
output=
while [[ "$#" -gt 0 ]]; do
    if [[ "$1" == -o ]]; then output="$2"; break; fi
    shift
done
[[ -n "$output" ]] || exit 90
if [[ "$output" == */tests/publish ]]; then
    cp "$PUBLISH_TEST_TOOL" "$output"
    exit 0
fi
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
        PUBLISH_TEST_TOOL="$test_root/publish" DOCKMAL_TEST_PAUSE_AT="${pause_at:-}" \
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
    local staging=("$output_parent"/.dockmal.*)
    check 'staging directories must be cleaned' test "${#staging[@]}" -eq 0
}
check_no_lock() {
    # Persistent files do not mean a held lock. A new process must acquire it.
    check 'publication lock must be reusable' "$test_root/publish" check "$output"
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

new_case successful_first_install
if ! run_build; then fail 'first build should succeed'; fi
check 'first publication installs a complete bundle' test -x "$output/Contents/MacOS/Dockmal"
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

new_case lock_symlink_is_rejected
printf '%s\n' preserve-lock-target > "$case_dir/lock-target"
ln -s "$case_dir/lock-target" "$output.build-lock"
if run_build; then fail 'lock symlink should reject publication'; fi
check 'lock symlink remains intact' test -L "$output.build-lock"
check 'lock target is unchanged' test "$(cat "$case_dir/lock-target")" = preserve-lock-target
check_no_staging
pass

for phase in before after; do
    new_case "sigkill_${phase}_atomic_publication"
    seed_old_bundle
    pause_at="$phase"
    run_build &
    build_pid=$!
    publisher_pid=
    for ((attempt = 0; attempt < 200; attempt++)); do
        publisher_pid="$(awk '$1 == "PUBLICATION_PAUSED" {print $2; exit}' "$log" 2>/dev/null || true)"
        if [[ -n "$publisher_pid" ]]; then break; fi
        sleep 0.05
    done
    if [[ -z "$publisher_pid" ]]; then
        wait "$build_pid" || true
        fail 'publisher did not reach the test barrier'
    fi
    if "$test_root/publish" check "$output" 2>/dev/null; then
        kill -KILL "$publisher_pid"
        wait "$build_pid" || true
        fail 'concurrent publisher must not acquire a held lock'
    fi
    # The output exists even while the publisher is paused on either side of swap.
    if [[ "$phase" == before ]]; then
        check 'old bundle stays in place before swap' diff -rq "$case_dir/expected-old.app" "$output"
    else
        check 'new bundle is complete immediately after swap' test -x "$output/Contents/MacOS/Dockmal"
        check 'old resources are absent after swap' test ! -e "$output/old-only-resource"
    fi
    kill -KILL "$publisher_pid"
    if wait "$build_pid"; then fail 'killed publisher must report failure'; fi
    publisher_pid=
    build_pid=
    pause_at=
    check_no_lock
    if ! run_build; then fail 'next build must succeed without deleting the lock'; fi
    check_no_staging
    pass
done

printf '%s packaging cases passed; app compiler and codesign were mocked.\n' "$cases"
