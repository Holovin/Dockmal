# dockmal

Dockmal is a macOS menu bar utility for the system Dock, targeting macOS 13+ on Apple Silicon.
The app name is Dockmal and its bundle identifier is `com.holovin-local.dockmal`.

## Project structure

- Native source: `Sources/`; offline regression tests: `Tests/`.
- Bundle publication helper: `Tools/publish.c`; build entry point: `build.sh`.
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

## Validation and versions

- For authorized native/build changes, use `bash build.sh` and `bash Tests/build-script-tests.sh` as appropriate.
- Offline tests must not install event taps, post input, or change system permissions.
- Successful tests and builds do not prove real Dock, drag, magnification, monitor, or Login Item behavior.
- Increment the native patch version and build number for each app update; repeat checks of the same change keep that version.
- The menu reads the version from the bundle. The Lua script has its own version.
- Do not commit generated bundles, signing certificates/keys, machine-specific paths, or credentials.
- Signing is not notarization.
