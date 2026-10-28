# Dock Double Click

A small macOS menu bar utility that requires a double-click to launch an app from the Dock.
Native app version: **0.0.7**. Requires macOS 13 or later on Apple Silicon.

Two alternatives are included: the native Swift app and a [Hammerspoon script](Hammerspoon/README.md) (version **0.2.1**). Run only one filter at a time.

## Behavior

- By default, running applications activate with one click; applications that are not running require two.
- The running state comes from Accessibility, not image recognition of the indicator dot.
- The first eligible left-button down/up pair is swallowed. A second click on the same icon within the system double-click interval and six points is forwarded as one ordinary click.
- The native app briefly dims the icon after the first blocked click. The dimming fades over 0.56 seconds and is dismissed by the next press, a drag, cancellation, or disabling the filter. With Reduce Motion it stays static until dismissal.
- Right clicks, modified clicks, folders, Trash, and minimized windows retain their normal behavior. Unknown running state passes through in the restricted mode.
- Moving more than six points hands the captured press back to Dock as a drag. Long holds do not arm a second click.
- Changing Dock preferences is not required.

## Menu

| Item | Meaning |
| --- | --- |
| Enabled | Enable or disable click filtering. |
| Only for apps not running | Keep single-click activation for running apps. Disabled while the filter is off. |
| Autostart | Register or unregister the native app as a macOS Login Item. |
| A11y | Current Accessibility permission state. |
| Version | App bundle version. |
| Quit | Exit the native app. |

The two filtering settings default to enabled and are saved between launches. Autostart reflects the system Login Item state and is not enabled automatically. When approval is required, the menu offers **Open Login Items Settings…**.

## Build and run

Install Xcode Command Line Tools with a Swift compiler that supports macOS 13 APIs, then run:

```sh
bash build.sh
open 'build/Dock Double Click.app'
```

The build runs the native checks, assembles a fresh bundle, applies an ad-hoc signature without a certificate, and verifies it before replacing an existing output. A failed build leaves the previous output available.

To use a signing identity from your own Keychain:

```sh
SIGNING_IDENTITY='your signing identity' bash build.sh
```

To choose a different output location:

```sh
APP_OUTPUT_PATH="$PWD/build-test/Dock Double Click.app" bash build.sh
```

Grant Accessibility access in **System Settings → Privacy & Security → Accessibility**. If permission is unavailable, the app shows a warning instead of filtering input. The menu provides a shortcut to these settings.

Keep an autostart-enabled app in a stable location. Signing is not notarization; this source repository does not include a distribution-ready app bundle. Rebuilding with an ad-hoc signature can require renewing Accessibility approval.

## Checks

`build.sh` runs the click state machine, overlay hit policy, icon geometry, and offline event-routing tests. Adapter tests use unposted events, fake hit testing, and a replay sink; they do not install an event tap or inject input.

A built executable can also report its version and permission state without starting filtering:

```sh
'build/Dock Double Click.app/Contents/MacOS/DockDoubleClick' --check
codesign --verify --deep --strict 'build/Dock Double Click.app'
```

Packaging regression checks use fake tools and temporary fixtures:

```sh
bash Tests/build-script-tests.sh
```

The Hammerspoon mock tests run separately and do not require starting Hammerspoon:

```sh
lua Hammerspoon/tests/test_dock_double_click.lua
```

Version 0.0.7 passes 250 native assertions and nine packaging scenarios; the Lua 0.2.1 harness passes 339 assertions in 29 scenarios.

## Limits of verification

Automated checks do not prove live Dock hit testing, dragging, auto-hide, Spaces, multiple monitors, or Login Item behavior. Verify these on the target Mac.

Icon feedback uses an alpha mask and measured Dock tile padding. A 68×79-point bottom-Dock item maps to a 64×64-point icon canvas with two points of padding along the Dock and five at the inward edge. This is empirical geometry, not an Apple API guarantee; other sizes, magnification, and side-Dock layouts require visual checks. Missing or unsupported visual metadata skips the effect while preserving click filtering.

The Hammerspoon alternative checks the global window order before its Dock-scoped Accessibility lookup so that an overlapping foreign window is not treated as Dock. Its mock coverage does not replace a live test of Accessibility or event replay.

## Implementation

The native app uses AppKit, CoreGraphics, Accessibility, QuartzCore, and ServiceManagement, with no third-party runtime dependencies. Input and Accessibility work run on a dedicated event thread; AppKit rendering stays on the main thread.

The implementation was written independently. Hammerspoon's [eventtap](https://github.com/Hammerspoon/hammerspoon/blob/23e387e2805a9890066366e0ac96c71b27f0cfd5/extensions/eventtap/libeventtap.m) and [axuielement](https://github.com/Hammerspoon/hammerspoon/blob/23e387e2805a9890066366e0ac96c71b27f0cfd5/extensions/axuielement/libaxuielement.m) sources were consulted as API references.
