# Dockmal

A small utility for the system Dock on macOS 13+ / Apple Silicon.
Built with Swift, AppKit, CoreGraphics, and Accessibility, with no external dependencies.
Bundle ID: `com.holovin-local.dockmal`.

Two alternatives are available: a standalone macOS app and a
[Hammerspoon Lua script](Hammerspoon/README.md). Enable only one at a time.

## Trying the app

1. **Disable the Dock Lua filter in Hammerspoon or quit Hammerspoon.**
   Running both filters would make them intercept each other's clicks.
2. Open `build/Dockmal.app`. A `2.brakesignal` icon appears in the menu bar
   (or a warning icon if permission has not been granted).
3. Grant the app access in **System Settings → Privacy & Security → Accessibility**.
   The app checks permission automatically; restart it if necessary.
4. By default, an app that is not running requires a double-click. A running app
   (with an indicator dot in the Dock) opens with one click.
5. Check right-clicks, icon dragging, Dock auto-hide, and a second monitor.
6. Uncheck **Enabled** to disable filtering, or choose **Quit** to exit.

## Native app menu

- **Enabled** turns the filter on. When off, event interception stops, the next
  item is disabled, and the Dock behaves normally.
- **Only for apps not running** requires a double-click only for apps that are
  not running. Running apps receive ordinary clicks and other gestures.
  The state comes from `AXIsApplicationRunning`, not the indicator dot's image.
- If only **Enabled** is checked, all apps require a double-click.
- Both settings default to enabled and persist between launches.
- After the separator, **Autostart** registers this app as a macOS Login Item
  using `SMAppService.mainApp`. It is independent of Enabled, is not turned on
  automatically, and reflects the system state without a separate saved flag.
  If system approval is required, the menu shows a mixed state and
  **Open Login Items Settings…**. Clicking Autostart again cancels registration.
- The gray **A11y: granted / not granted** and **Version** rows show Accessibility
  permission and the bundle version. States are refreshed before the menu opens.
- Enable Autostart from a permanent location for the signed app. Do not move or
  delete the bundle after registration without checking Login Items in System Settings.

## Click handling

- Before AX hit testing, the app checks fresh Dock window bounds from WindowServer.
  Clicks outside those bounds do not query Accessibility in the app under the
  pointer. Unknown metadata falls back to the ordinary AX lookup. This spatial
  prefilter does not replace the topmost-element check or cache Dock geometry.
- The first ordinary left-click on a filtered icon is swallowed completely.
- In the native app, the first blocked click slightly dims the icon, then the
  dimming fades over 0.56 seconds. The effect follows the app image's alpha mask;
  there is no ring, scaling, or spring animation. The next press, drag start,
  gesture cancellation, or disabling the filter dismisses it. With Reduce Motion,
  the dimming stays static and is then removed. Positioning uses Accessibility
  geometry, accounting for Dock tile padding and the running-indicator gutter.
  Fractional coordinates are preserved when macOS rounds the window position.
  Missing or unsupported geometry or images skip the effect without disabling
  click filtering.
- A second click on the same icon within the system double-click interval reaches
  the Dock as one ordinary click. The app's running state is checked on every press.
- In the restricted mode, an unknown running state passes the click through.
- Movement between clicks is limited to six logical points.
- Right-clicks, Cmd/Option/Ctrl/Shift/Fn-modified clicks, folders, Trash, and
  minimized windows pass through normally. This filters ordinary left-clicks;
  it does not block other ways of launching apps.
- Moving more than six points hands the held icon back to the Dock for dragging.
  This behavior requires verification with the real Dock.
- Long left-button holds on filtered icons are swallowed. Use a right-click for
  the context menu. A long hold does not arm the next double-click.
- Failed target lookups pass the event through. Repeated timeouts stop
  interception and show a warning icon.
- When the filter stops, an already swallowed press remains captured until
  release; new gestures are not intercepted. Re-enabling waits for the old tap
  to finish. A Dock restart or recovery from a tap timeout cancels double-click
  recognition while continuing to swallow the remaining drag/up events without
  replaying a stale down. If the system forcibly disables the tap, permission is
  lost, or the process exits, delivery of the remaining mouse-up cannot be guaranteed.
- The filter restarts after sleep or a change of active user session.
- Dock preferences are not changed. Autostart is registered only by clicking
  Autostart; no separate helper, LaunchAgent, or hidden daemon is created.

## Building and signing

For every app update, increment the patch version in `CFBundleShortVersionString`
and the build number in `CFBundleVersion` in `Info.plist`. The menu reads its
version from the bundle. Rechecking the same change does not create a new version.

The installed toolchain is Xcode / Swift 6.2; sources compile in Swift 5 mode.

```sh
bash build.sh
SIGNING_IDENTITY='identity from security find-identity -v -p codesigning' bash build.sh
```

Choose another output path to avoid replacing the bundle currently in use:

```sh
APP_OUTPUT_PATH="$PWD/.build/staging/Dockmal.app" bash build.sh
```

The build runs the logic and event-adapter tests without a live event tap, then
creates and verifies a new ARM64 `.app` in a temporary directory beside the output
bundle. The previous build is replaced only after successful checks. Without
`SIGNING_IDENTITY`, the build uses an ad-hoc signature without a certificate.
Apple Development signing is suitable for local test builds; it is not a
Developer ID distribution build or a notarized release.

Publication uses a system lock and an atomic directory swap on the same filesystem.
The `Dockmal.app.build-lock` file remains on disk; this is normal and it should not
be deleted. The kernel releases the lock when the process exits, including after
SIGKILL. A filesystem without atomic-swap support rejects publication and preserves
the previous bundle. A hard interruption may leave a `.dockmal.*` staging directory,
but replacement does not leave the output bundle missing. Legacy lock directories
are not removed automatically: the build message explains how to check the previous
app and recover manually.

Safe checks of a built executable (no interception or permission prompts):

```sh
'build/Dockmal.app/Contents/MacOS/Dockmal' --check
codesign --verify --deep --strict --verbose=2 'build/Dockmal.app'
```

## Limits of verification

Tests check the state machine, and a build checks compatibility with the macOS SDK.
Neither proves live AX hit testing, Dock interaction, dragging, auto-hide, or Spaces.
These scenarios require manual verification.

Swift tests cover clicks, window order, geometry, event routing, and highlight
cancellation. The Lua 0.2.1 mock harness passed 339 assertions in 29 scenarios.
Real clicks and menu state were not checked automatically.

Packaging checks use the real C publication helper with a mocked app compiler and
signing tool. They also cover SIGKILL before and after atomic replacement:

```sh
bash Tests/build-script-tests.sh
```

Autostart requires separate manual checks of registration, system approval,
disabling, and the next macOS login. Neither the build nor `--check` registers it.

The dimming effect uses a separate panel that does not take focus or handle mouse
input. If it becomes the topmost AX window, an additional window-order check allows
a Dock lookup only when a Dock window is directly underneath it. Foreign windows
and the app's own menus are not bypassed. Pure tests check this policy and geometry
validation; real second clicks, dragging, Dock magnification, auto-hide, and multiple
displays with visible feedback still require manual checks. Image padding was
calibrated against a supplied bottom-Dock screenshot: a 68×79-point tile contains
a 64×64-point image with two points of padding along the Dock and five at the inward
edge. This is observed geometry, not an Apple API guarantee. Applying the model to
side Docks or other sizes requires visual verification. The Lua alternative does
not draw the dimming effect.

The implementation was written independently using public APIs. Hammerspoon's
sources were consulted as reference material:
[eventtap](https://github.com/Hammerspoon/hammerspoon/blob/23e387e2805a9890066366e0ac96c71b27f0cfd5/extensions/eventtap/libeventtap.m),
[axuielement](https://github.com/Hammerspoon/hammerspoon/blob/23e387e2805a9890066366e0ac96c71b27f0cfd5/extensions/axuielement/libaxuielement.m).
