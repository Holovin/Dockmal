# Dockmal

Dockmal is a utility that makes apps in the Dock launch on a double-click; files
and Trash are unaffected. Extra settings in the menu bar: double-click only for
apps that aren’t running; autostart. On first launch, grant Dockmal access in
**System Settings → Privacy & Security → Accessibility**.

Download the DMG from [Releases](https://github.com/Holovin/DockMal/releases).
Universal build (Apple Silicon and Intel), macOS 13 or later.
This build is not notarized by Apple, so macOS blocks it on first launch. After dragging
Dockmal to Applications, run this once in Terminal:

```
xattr -dr com.apple.quarantine /Applications/Dockmal.app
```

macOS asks for Accessibility access again after every update, because the build is signed
without a developer certificate.

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

Hammerspoon’s [eventtap](https://github.com/Hammerspoon/hammerspoon/blob/23e387e2805a9890066366e0ac96c71b27f0cfd5/extensions/eventtap/libeventtap.m)
and [axuielement](https://github.com/Hammerspoon/hammerspoon/blob/23e387e2805a9890066366e0ac96c71b27f0cfd5/extensions/axuielement/libaxuielement.m)
sources were consulted as references for the independent native implementation.
