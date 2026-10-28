# Dock Double Click development

- Native code is in `Sources/`; regression tests are in `Tests/`.
- `Hammerspoon/` contains an alternative filter. Never run both filters together.
- Preserve the English menu and the default single-click behavior for running apps.
- Keep AppKit rendering on the main thread; event and Accessibility state belongs to the event thread.
- Unknown app eligibility or failed hit testing must pass the original click through.
- Run `bash build.sh`, `bash Tests/build-script-tests.sh`, and the standalone Lua mock harness after relevant changes.
- Automated checks do not replace real Dock, drag, monitor, or Login Item testing. Do not inject input, reload Hammerspoon, or change system permissions as part of automated tests.
- Do not commit generated bundles, signing material, machine-specific paths, or credentials.
- Increment the native patch version and build number for an app update; retain the Lua script's separate version.
