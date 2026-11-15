# Changelog

## 0.0.13

- Build a universal app (Apple Silicon and Intel).
- Publish an ad-hoc signed DMG to GitHub Releases when the version in `Info.plist` changes on `master`.

## 0.0.12

- Align the GitHub link with the product caption's text baseline and use matching gray text while keeping the link clickable.

## 0.0.11

- Replace the Version row with a disabled Dockmal/version caption and a separate GitHub link in the same menu row.

## 0.0.10

- Reject clicks outside current Dock window bounds before synchronous Accessibility hit testing.
- Avoid idle feedback dispatches while still cancelling pending icon loads and queued highlights.
- Drain intercepted mouse presses before stopping the tap; preserve suppression across Dock changes and recoverable tap timeouts.
- Publish bundles using a kernel-managed lock and an atomic directory swap so killed publishers cannot strand a lock or leave the output missing.
- Correct the standalone app name in Hammerspoon instructions and remove duplicated version numbers from the native README.

## 0.0.9

- Change the native bundle identifier to `com.holovin-local.dockmal`.

## 0.0.8

- Rename the native app, executable, and visible interface strings to Dockmal.
- Retain the bundle identifier and preference keys to preserve app identity and settings.

## 0.0.7

- Recheck event-filter configuration after Accessibility lookup so a stop or mode change cannot apply a stale click decision.
- Keep the remaining drag/up pair suppressed if copying the drag for replay fails.
- Add offline adapter regressions that exercise the production event-routing path without posting input or starting an event tap.
- Build and verify a fresh app bundle before replacing the output. Use an ad-hoc signature when no signing identity is supplied, and keep test executables isolated between concurrent builds.
- Hammerspoon 0.2.1: make repeated activation idempotent, retain ownership of an in-flight press across disable/enable, and check topmost window ownership before capturing Dock clicks.

## 0.0.6

- Add Autostart, Accessibility status, and version menu entries.
- Show a brief icon dimming effect after the first blocked click.
- Align the alpha mask with the icon canvas and preserve fractional screen coordinates.
