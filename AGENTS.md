# dockmal

Dockmal is a macOS menu bar utility for the system Dock, targeting macOS 13+ as a universal
(Apple Silicon and Intel) build.
The app name is Dockmal and its bundle identifier is `com.holovin-local.dockmal`.

## Project structure

- Native source: `Sources/`; offline regression tests: `Tests/`.
- Bundle publication helper: `Tools/publish.c`; build entry point: `build.sh`.
- CI: `.github/workflows/build.yml` runs `build.sh` and the packaging tests on GitHub
  Actions and uploads an ad-hoc signed `Dockmal.zip` artifact.
- Releases: `.github/workflows/release.yml` publishes a DMG to GitHub Releases when a push
  to `master` changes the version in `Info.plist` and the tag `v<version>` does not exist yet.
- Hammerspoon alternative: the single root file `dock_double_click.lua`, documented in `README.md`.
  Do not add a separate Hammerspoon directory, test harness, or README.
- Keep documentation, comments, interface text, and commit messages in English.

## Behavior

- `Enabled` and `Only for apps not running` default to true and persist between launches.
- Running apps receive one click; stopped apps require two. Unknown eligibility passes through.
- Keep AppKit rendering on the main thread and event/Accessibility state on the event thread.
- Preserve ownership of intercepted down/up pairs during cancellation and recoverable transitions.
- Never run the native and Hammerspoon filters together or silently install/reload Hammerspoon.
- Do not change Dock preferences or register Autostart as a side effect of checks.

## Building and signing

With Xcode’s command-line tools available, run from the project folder:

```sh
bash build.sh
open build/Dockmal.app
```

`bash build.sh` runs the offline Swift tests, builds the universal app, signs it, and
verifies the signature. Packaging tests run separately:

```sh
bash Tests/build-script-tests.sh
```

Builds use an ad-hoc signature by default. To use a signing identity:

```sh
SIGNING_IDENTITY='your signing identity' bash build.sh
```

Apple Development signing is suitable for local testing; it does not produce a
notarized release.

To build somewhere else, for example while another copy is running:

```sh
APP_OUTPUT_PATH="$PWD/.build/staging/Dockmal.app" bash build.sh
```

A successful build atomically replaces the previous app. The `.build-lock` file
beside it is normal: leave it in place. Its lock is released when the build exits,
even if the process is killed.

Check a built app without intercepting input or requesting permissions:

```sh
'build/Dockmal.app/Contents/MacOS/Dockmal' --check
codesign --verify --deep --strict --verbose=2 'build/Dockmal.app'
```

## Limits of verification

- Tests cover pure logic and event routing with mocks; they never touch the live Dock,
  Accessibility, or Login Items. Those need manual checks.
- Icon dimming geometry is calibrated only for a bottom Dock (a 68×79-point tile holds
  a 64×64-point image). Side Docks, other sizes, and magnification are unverified.

## Validation and versions

- For authorized native/build changes, use `bash build.sh` and `bash Tests/build-script-tests.sh` as appropriate.
- Offline tests must not install event taps, post input, or change system permissions.
- Increment the native patch version and build number for each app update; repeat checks of the same change keep that version.
- The menu reads the version from the bundle. The Lua script has its own version.
- Do not commit generated bundles, signing certificates/keys, machine-specific paths, or credentials.
- Signing is not notarization.
