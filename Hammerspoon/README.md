# Dock Double Click for Hammerspoon

[dock_double_click.lua](dock_double_click.lua) is a standalone alternative to the
native app. Version 0.2.1 targets Hammerspoon 1.1.x / Lua 5.4.

## Manual installation

1. Quit the standalone Dockmal app using **Quit**. Do not enable both filters
   at the same time.
2. Back up your existing script, if any, then copy `dock_double_click.lua` to
   `~/.hammerspoon/`.
3. Add the following line to `~/.hammerspoon/init.lua` if it is not already present:

   ```lua
   dofile(hs.configdir .. "/dock_double_click.lua")
   ```

4. Choose **Reload Config** in Hammerspoon and grant Accessibility access if needed.
   If access is denied, grant it in System Settings and choose **Retry** in `D²`.

The repository does not install or reload Hammerspoon automatically.

## D² menu

| Item | Action |
| --- | --- |
| Enabled | Turn filtering on or off. When off, the next item is disabled. |
| Only for apps not running | Require a double-click only for apps that are not running; running apps activate with one click. |
| Unload script | Unload this script and its menu, leaving Hammerspoon and other automations running. |

Both settings default to enabled. If the second is off, all application icons
require a double-click. Settings persist in `hs.settings` across Reload Config
and restarts; they are not synchronized with the native app's settings.

After Unload script, calling `dofile` again or using Reload Config restores the
module with its saved settings. To keep filtering disabled, uncheck **Enabled**.

## Behavior

The first ordinary left-button down/up pair is swallowed. A second click on the
same icon within the system interval reaches the Dock as an ordinary single click.
Movement is limited to six logical points. A long hold does not arm a double-click.
When a drag begins, the script replays the saved down and drag into the event stream.

Right-clicks, modified clicks, folders, Trash, and minimized windows pass through
normally. Running state comes from `AXIsApplicationRunning`; an unknown state
passes the click through in Only for apps not running mode. An exception stops
the filter and offers Retry in the menu. Dock preferences are not changed.

Before the AX lookup, the script reads global window order using `hs.window.list(true)`.
A click is filtered only if the topmost visible window at that point belongs to
the Dock. An overlapping foreign window or unknown owner/geometry passes the click
through. Hammerspoon's global AX timeout is not changed.

Repeated `start()` / `setEnabled(true)` calls do not restart a running filter and
preserve any captured down/up pair. Disabling cancels the pending double-click;
re-enabling before release preserves handling of that cancelled pair.

## Console and optional hotkey

```lua
dockDoubleClick.status()
dockDoubleClick.setEnabled(false)
dockDoubleClick.setEnabled(true)
dockDoubleClick.setOnlyStoppedApps(true)
dockDoubleClick.inspect() -- prints AX attributes under the pointer after three seconds
```

No global hotkey is assigned automatically. If needed, explicitly bind an unused
combination after the `dofile` line, for example:

```lua
dockDoubleClick.hotkey = hs.hotkey.bind(
    { "ctrl", "alt", "cmd" }, "D", dockDoubleClick.toggle
)
```

Reloading or choosing Unload script removes this hotkey. Choose a combination
that other scripts do not use.

## Testing without starting Hammerspoon

From the repository root, with standalone Lua installed:

```sh
lua Hammerspoon/tests/test_dock_double_click.lua
```

The harness fully mocks `hs`; it does not intercept input or change real settings.
It passed 339 assertions in 29 scenarios on host Lua 5.5.1. The actual embedded
Lua 5.4 runtime, AX hit testing, window order, dragging, auto-hide, multiple displays,
and event-tap recovery require separate testing on a Mac.
