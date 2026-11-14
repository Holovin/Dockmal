# Changelog

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
