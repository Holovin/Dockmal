# Dockmal

Dockmal helps prevent accidental app launches from your Mac’s Dock. Apps that
aren’t running take a double-click to open.

A small menu bar app for **macOS 13+ on Apple Silicon**.

## Get started

With Xcode’s command-line tools available, run these commands from the project folder:

```sh
bash build.sh
open build/Dockmal.app
```

Grant Dockmal access in **System Settings → Privacy & Security → Accessibility**.
The app checks permission automatically; restart it if needed. Then try an app
that isn’t running: the first click briefly dims its icon, and the second opens it.
Dockmal uses your system’s double-click interval.

## Make it yours

Open Dockmal’s menu in the menu bar:

- **Enabled** — turn filtering on or off.
- **Only for apps not running** — turn this off to require a double-click for every app.
- **Autostart** — start Dockmal when you log in. Off by default; macOS may ask for approval.

The first two settings are on by default and remembered between launches.
The menu also shows Accessibility status. Choose **Quit** to exit.

Keep the app in a permanent location before enabling Autostart.

## Good to know

- Right-clicks, clicks with modifier keys, folders, Trash, and minimized windows work normally.
- Use a right-click for context menus: holding the left button on a filtered icon won’t open one.
- Dockmal leaves your Dock preferences alone. Turning it off restores ordinary clicks.
- Dragging, Dock magnification, auto-hide, side Docks, and multiple displays still need
  manual verification. The dimming effect may not align at every Dock size or position.

## Using Hammerspoon?

[dock_double_click.lua](dock_double_click.lua) is a standalone alternative with the
same click filtering, without the dimming effect. **Use one filter at a time.**

1. Quit Dockmal.
2. Copy the script to `~/.hammerspoon/`, backing up any existing copy.
3. Add this line to `~/.hammerspoon/init.lua`:

   ```lua
   dofile(hs.configdir .. "/dock_double_click.lua")
   ```

4. Choose **Reload Config** in Hammerspoon and grant Accessibility access if needed.
   Use **Retry** in the **D²** menu after granting permission.

The **D²** menu has the same two filter settings, saved independently of Dockmal.
**Unload script** removes the script and its menu until the next reload.

## Development

Written in Swift and AppKit. `bash build.sh` runs offline Swift tests, builds the
app, and verifies its signature. Packaging tests run separately:

```sh
bash Tests/build-script-tests.sh
```

These checks don’t exercise the live Dock or verify Autostart at login.
See [CHANGELOG.md](CHANGELOG.md) for changes.

<details>
<summary>Signing, build output, and diagnostics</summary>

Builds use an ad-hoc signature by default. To use your own signing identity:

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

</details>

Hammerspoon’s [eventtap](https://github.com/Hammerspoon/hammerspoon/blob/23e387e2805a9890066366e0ac96c71b27f0cfd5/extensions/eventtap/libeventtap.m)
and [axuielement](https://github.com/Hammerspoon/hammerspoon/blob/23e387e2805a9890066366e0ac96c71b27f0cfd5/extensions/axuielement/libaxuielement.m)
sources were consulted as references for the independent native implementation.
