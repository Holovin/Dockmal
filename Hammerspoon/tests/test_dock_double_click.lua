-- Standalone behavioral tests: no real Hammerspoon APIs or input are used.
-- Run with Lua 5.4+ from any working directory:
--   lua /path/to/Hammerspoon/tests/test_dock_double_click.lua

local thisFile = debug.getinfo(1, "S").source:sub(2)
local scriptDirectory = thisFile:match("^(.*)/") or "."
local scriptPath = arg[1] or (scriptDirectory .. "/../dock_double_click.lua")
local assertions, cases, failures = 0, 0, 0

local function equal(actual, expected, message)
    assertions = assertions + 1
    if actual ~= expected then
        error((message or "Unexpected value") .. ": expected " .. tostring(expected)
            .. ", got " .. tostring(actual), 2)
    end
end

local function truthy(value, message)
    equal(not not value, true, message)
end

local function clone(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = clone(item) end
    return setmetatable(result, getmetatable(value))
end

local Event = {}
Event.__index = Event
function Event:getType() return self.kind end
function Event:getFlags() return clone(self.flags) end
function Event:location() return clone(self.point) end
function Event:getProperty(key) return self.properties[key] or 0 end
function Event:setProperty(key, value) self.properties[key] = value; return self end
function Event:timestamp(value)
    if value ~= nil then self.time = value; return self end
    return self.time
end
function Event:copy() return clone(self) end

local T = {
    leftMouseDown = 1, leftMouseUp = 2, leftMouseDragged = 3,
    rightMouseDown = 4, otherMouseDown = 5, scrollWheel = 6,
    flagsChanged = 7,
}
local P = { mouseEventClickState = 1, eventSourceUserData = 2 }

local function fixture(saved)
    _G.dockDoubleClick = nil
    local f = {
        saved = clone(saved or {}), writes = {}, taps = {}, menus = {},
        hotkeys = {}, timers = {}, alerts = {}, permissionCalls = {},
        accessibility = true, now = 10e9, interval = 0.5,
        dockPID = 42, dockExists = true, axHitTests = 0,
    }
    function f.app(running, key, subrole)
        local element = { values = {
            AXRole = "AXDockItem",
            AXSubrole = subrole or "AXApplicationDockItem",
            AXURL = key or "file:///Applications/Example.app",
            AXIsApplicationRunning = running,
        } }
        function element:setTimeout() return not self.failTimeout end
        function element:attributeValue(name)
            if f.throwAX then error("Injected AX failure") end
            return self.values[name]
        end
        return element
    end
    function f.window(owner, bounds)
        return { kCGWindowOwnerPID = owner,
            kCGWindowBounds = bounds or { X = -100, Y = -100, Width = 400, Height = 400 },
            kCGWindowAlpha = 1, kCGWindowIsOnscreen = true }
    end
    f.target = f.app(false)
    local dock = {}
    function dock:pid() return f.dockPID end
    local ax = {}
    function ax:setTimeout() return not f.failDockTimeout end
    function ax:elementAtPosition(point)
        f.axHitTests = f.axHitTests + 1
        if f.targetAt then return f.targetAt(point) end
        return f.target, f.axError
    end
    _G.hs = {
        settings = {
            get = function(key) return f.saved[key] end,
            set = function(key, value)
                f.saved[key] = value
                f.writes[#f.writes + 1] = { key = key, value = value }
            end,
        },
        eventtap = {
            event = { types = T, properties = P },
            doubleClickInterval = function() return f.interval end,
            new = function(types, callback)
                local tap = { types = types, callback = callback, enabled = false,
                    starts = 0, stops = 0 }
                function tap:start()
                    self.starts = self.starts + 1
                    self.enabled = not f.failTapStart
                    return self
                end
                function tap:stop()
                    self.stops = self.stops + 1
                    self.enabled = false
                    return self
                end
                function tap:isEnabled() return self.enabled end
                f.taps[#f.taps + 1] = tap
                return tap
            end,
        },
        application = {
            applicationsForBundleID = function(id)
                equal(id, "com.apple.dock", "AX query must target Dock")
                return f.dockExists and { dock } or {}
            end,
        },
        window = {
            list = function(allWindows)
                equal(allWindows, true, "Window lookup must retain Dock and higher-level windows")
                if f.windowList ~= nil then return clone(f.windowList) end
                return { f.window(f.dockPID) }
            end,
        },
        axuielement = {
            applicationElement = function() return ax end,
            systemElementAtPosition = function() return f.target end,
        },
        menubar = {
            new = function()
                local menu = { deleted = false }
                function menu:setTitle(value) self.title = value; return self end
                function menu:setTooltip(value) self.tooltip = value; return self end
                function menu:setIcon(value) self.icon = value; return self end
                function menu:setMenu(value) self.menu = value; return self end
                function menu:delete() self.deleted = true end
                f.menus[#f.menus + 1] = menu
                return menu
            end,
        },
        hotkey = {
            bind = function(modifiers, key, callback)
                local hotkey = { modifiers = modifiers, key = key, callback = callback }
                function hotkey:delete() self.deleted = true end
                f.hotkeys[#f.hotkeys + 1] = hotkey
                return hotkey
            end,
        },
        timer = {
            absoluteTime = function() return f.now end,
            doAfter = function(delay, callback)
                local timer = { delay = delay, callback = callback }
                function timer:stop() self.stopped = true end
                f.timers[#f.timers + 1] = timer
                return timer
            end,
        },
        accessibilityState = function(request)
            f.permissionCalls[#f.permissionCalls + 1] = { request = request }
            return f.accessibility
        end,
        alert = { show = function(message) f.alerts[#f.alerts + 1] = message end },
        mouse = { absolutePosition = function() return { x = 0, y = 0 } end },
        inspect = function(value) return tostring(value) end,
    }
    function f.load()
        f.module = assert(loadfile(scriptPath))()
        return f.module
    end
    function f.event(kind, seconds, options)
        options = options or {}
        return setmetatable({ kind = T[kind], time = (seconds or 1) * 1e9,
            point = { x = options.x or 0, y = options.y or 0 },
            flags = options.flags or {},
            properties = { [P.mouseEventClickState] = options.clicks or 1,
                [P.eventSourceUserData] = options.tag or 0 },
        }, Event)
    end
    function f.send(kind, seconds, options)
        local event = f.event(kind, seconds, options)
        local suppressed, extra = f.module.tap.callback(event)
        return suppressed, extra, event
    end
    function f.click(seconds, options)
        local down = f.send("leftMouseDown", seconds, options)
        local up = f.send("leftMouseUp", seconds + 0.05, options)
        return down, up
    end
    function f.row(title)
        local menu = f.module.menu
        local rows = type(menu.menu) == "function" and menu.menu() or menu.menu
        for _, row in ipairs(rows) do
            if row.title == title then return row end
        end
        error("Missing menu row: " .. title)
    end
    return f
end

local function test(name, fn)
    cases = cases + 1
    local ok, err = pcall(fn)
    if ok then
        print("PASS " .. name)
    else
        failures = failures + 1
        io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
    end
end

test("default settings, menu and retained module", function()
    local f = fixture()
    local m = f.load()
    equal(_G.dockDoubleClick, m)
    equal(m.enabled, true)
    equal(m.config.onlyStoppedApps, true)
    equal(m.tap:isEnabled(), true)
    equal(#f.writes, 0, "Loading defaults must not overwrite saved preferences")
    local registered = {}
    for _, kind in ipairs(m.tap.types) do registered[kind] = true end
    for name, kind in pairs(T) do truthy(registered[kind], "Tap must register " .. name) end
    equal(type(m.menu.menu), "function", "Menu must reflect current settings")
    equal(f.row("Enabled").checked, true)
    equal(f.row("Only for apps not running").checked, true)
    equal(not not f.row("Only for apps not running").disabled, false)
    equal(type(f.row("Unload script").fn), "function")
    equal(#f.hotkeys, 0, "Enabled startup must not register or shadow existing hotkeys")
end)

test("running apps preserve ordinary single clicks by default", function()
    local f = fixture(); f.target = f.app(true); f.load()
    local down, up = f.click(1)
    equal(down, false); equal(up, false)
end)

test("stopped app needs a second click normalized for the Dock", function()
    local f = fixture(); f.load()
    local down, up = f.click(1)
    equal(down, true); equal(up, true)
    local secondDown, _, downEvent = f.send("leftMouseDown", 1.2, { clicks = 2 })
    local secondUp, _, upEvent = f.send("leftMouseUp", 1.25, { clicks = 2 })
    equal(secondDown, false); equal(secondUp, false)
    equal(downEvent:getProperty(P.mouseEventClickState), 1)
    equal(upEvent:getProperty(P.mouseEventClickState), 1)
end)

test("unknown running state fails open", function()
    for _, running in ipairs({ "unknown", "false", 0 }) do
        local f = fixture(); f.target = f.app(running); f.load()
        equal(f.send("leftMouseDown", 1), false)
        equal(f.send("leftMouseUp", 1.05), false)
    end
    local f = fixture(); f.target = f.app(nil); f.load()
    equal(f.send("leftMouseDown", 1), false)
    equal(f.send("leftMouseUp", 1.05), false)
end)

test("all-apps mode also captures running apps", function()
    local f = fixture(); f.target = f.app(true); local m = f.load()
    m.setOnlyStoppedApps(false)
    equal(m.config.onlyStoppedApps, false)
    equal(f.saved["dockDoubleClick.onlyStoppedApps"], false)
    local down, up = f.click(1)
    equal(down, true); equal(up, true)
    equal(f.send("leftMouseDown", 1.2, { clicks = 2 }), false)
end)

test("saved false settings survive load without prompting or starting tap", function()
    local f = fixture({ ["dockDoubleClick.enabled"] = false,
        ["dockDoubleClick.onlyStoppedApps"] = false })
    local m = f.load()
    equal(m.enabled, false); equal(m.config.onlyStoppedApps, false)
    equal(m.tap:isEnabled(), false); equal(m.tap.starts, 0)
    equal(#f.hotkeys, 0, "Disabled startup must not register or shadow existing hotkeys")
    for _, call in ipairs(f.permissionCalls) do
        equal(not not call.request, false, "Disabled script must not request Accessibility")
    end
    equal(f.row("Enabled").checked, false)
    equal(f.row("Only for apps not running").checked, false)
    equal(f.row("Only for apps not running").disabled, true)
end)

test("nonboolean saved settings fall back to enabled defaults", function()
    local f = fixture({ ["dockDoubleClick.enabled"] = 0,
        ["dockDoubleClick.onlyStoppedApps"] = "false" })
    local m = f.load()
    equal(m.enabled, true); equal(m.config.onlyStoppedApps, true)
    equal(#f.writes, 0)
end)

test("missing Accessibility permission preserves intent and offers retry", function()
    local f = fixture(); f.accessibility = false; local m = f.load()
    equal(m.enabled, true); equal(m.tap:isEnabled(), false)
    equal(m.tap.starts, 0)
    equal(f.row("Enabled").checked, true)
    f.accessibility = true
    f.row("Retry").fn()
    equal(m.tap:isEnabled(), true)
end)

test("menu callbacks persist both preferences and update disabled state", function()
    local f = fixture(); local m = f.load()
    f.row("Only for apps not running").fn()
    equal(m.config.onlyStoppedApps, false)
    equal(f.saved["dockDoubleClick.onlyStoppedApps"], false)
    equal(f.row("Only for apps not running").checked, false)
    f.row("Enabled").fn()
    equal(m.enabled, false); equal(m.tap:isEnabled(), false)
    equal(f.saved["dockDoubleClick.enabled"], false)
    equal(f.row("Only for apps not running").disabled, true)
    f.row("Enabled").fn()
    equal(m.enabled, true); equal(m.tap:isEnabled(), true)
    equal(f.saved["dockDoubleClick.enabled"], true)
    equal(not not f.row("Only for apps not running").disabled, false)
end)

test("public start stop and toggle share persistent Enabled preference", function()
    local f = fixture(); local m = f.load()
    m.stop()
    equal(m.enabled, false); equal(f.saved["dockDoubleClick.enabled"], false)
    equal(m.tap:isEnabled(), false)
    m.start()
    equal(m.enabled, true); equal(f.saved["dockDoubleClick.enabled"], true)
    m.toggle(); equal(m.enabled, false)
    m.toggle(); equal(m.enabled, true)
end)

test("repeated start preserves a captured pair and pending recognition", function()
    local f = fixture(); local m = f.load()
    equal(f.send("leftMouseDown", 1), true)
    local starts, permissions = m.tap.starts, #f.permissionCalls
    equal(m.start(), true)
    equal(m.tap.starts, starts, "Active start must not restart the tap")
    equal(#f.permissionCalls, permissions, "Active start must not prompt again")
    equal(f.send("leftMouseUp", 1.05), true, "Its swallowed down still owns this up")
    equal(m.setEnabled(true), true)
    equal(f.send("leftMouseDown", 1.2, { clicks = 2 }), false,
        "Idempotent start must preserve the completed first click")
    local suppressed, _, up = f.send("leftMouseUp", 1.25, { clicks = 2 })
    equal(suppressed, false); equal(up:getProperty(P.mouseEventClickState), 1)
end)

test("stop then start while held drains the cancelled pair", function()
    local f = fixture(); local m = f.load()
    equal(f.send("leftMouseDown", 1), true)
    m.stop()
    equal(m.tap:isEnabled(), true, "Stopping must retain the tap until its captured up")
    local starts = m.tap.starts
    m.start()
    equal(m.tap.starts, starts, "Re-enabling a draining tap must not reset ownership")
    equal(f.send("leftMouseUp", 1.05), true, "Re-enabled tap must swallow the owned up")
    equal(m.tap:isEnabled(), true)
    equal(f.send("leftMouseDown", 1.2, { clicks = 2 }), true,
        "A click cancelled by disabling must not arm the next click")
end)

test("repeated start preserves normalization of an accepted pair", function()
    local f = fixture(); local m = f.load(); f.click(1)
    equal(f.send("leftMouseDown", 1.2, { clicks = 2 }), false)
    m.start()
    local suppressed, _, up = f.send("leftMouseUp", 1.25, { clicks = 2 })
    equal(suppressed, false); equal(up:getProperty(P.mouseEventClickState), 1)
end)

test("foreign topmost window passes through despite a Dock AX candidate", function()
    local f = fixture(); f.load()
    f.windowList = { f.window(77), f.window(f.dockPID) }
    local down, up = f.click(1)
    equal(down, false); equal(up, false)
    equal(f.axHitTests, 0, "Foreign topmost ownership must prevent a scoped Dock hit test")
    f.windowList = { f.window(f.dockPID), f.window(77) }
    down, up = f.click(1.2)
    equal(down, true); equal(up, true, "A window behind Dock must not block filtering")
end)

test("foreign overlay between clicks cancels pending recognition", function()
    local f = fixture(); f.load(); f.click(1)
    f.windowList = { f.window(77), f.window(f.dockPID) }
    local down, up = f.click(1.2, { clicks = 2 })
    equal(down, false); equal(up, false)
    f.windowList = nil
    equal(f.send("leftMouseDown", 1.4), true,
        "Removing the overlay must not revive the earlier pending Dock click")
end)

test("known invisible and outside windows do not obscure Dock", function()
    local f = fixture(); f.load()
    local transparent, offscreen = f.window(77), f.window(88)
    transparent.kCGWindowAlpha = 0
    offscreen.kCGWindowIsOnscreen = false
    f.windowList = { transparent, offscreen,
        f.window(99, { X = 500, Y = 500, Width = 100, Height = 100 }), f.window(f.dockPID) }
    local down, up = f.click(1)
    equal(down, true); equal(up, true)
end)

test("unknown topmost ownership or window metadata fails open", function()
    local mutations = {
        function(w) w.kCGWindowOwnerPID = nil end,
        function(w) w.kCGWindowOwnerPID = 0 end,
        function(w) w.kCGWindowBounds = nil end,
        function(w) w.kCGWindowBounds.X = math.huge end,
        function(w) w.kCGWindowAlpha = nil end,
        function(w) w.kCGWindowIsOnscreen = nil end,
    }
    for _, mutate in ipairs(mutations) do
        local f = fixture(); f.load()
        local unknown = f.window(f.dockPID); mutate(unknown)
        f.windowList = { unknown, f.window(f.dockPID) }
        local down, up = f.click(1)
        equal(down, false); equal(up, false)
        equal(f.axHitTests, 0)
        equal(f.module.tap:isEnabled(), true, "Unknown metadata is not an exception")
    end
    for _, unavailable in ipairs({ false, {} }) do
        local f = fixture(); f.windowList = unavailable; f.load()
        local down, up = f.click(1)
        equal(down, false); equal(up, false)
        equal(f.axHitTests, 0)
    end
end)

test("reload cleans old resources and retains saved preferences", function()
    local f = fixture(); local old = f.load()
    old.hotkey = hs.hotkey.bind({ "ctrl", "alt", "cmd" }, "D", old.toggle)
    local oldMenu, oldHotkey = old.menu, old.hotkey
    old.setOnlyStoppedApps(false)
    old.setEnabled(false)
    old.inspect()
    local timer = old.inspectTimer
    local reloaded = f.load()
    equal(old.tap:isEnabled(), false)
    equal(oldMenu.deleted, true); equal(oldHotkey.deleted, true)
    truthy(timer and timer.stopped, "Reload must stop outstanding inspection timer")
    equal(reloaded.enabled, false); equal(reloaded.config.onlyStoppedApps, false)
    equal(reloaded.tap:isEnabled(), false)
    reloaded.start()
    local active = 0
    for _, tap in ipairs(f.taps) do if tap:isEnabled() then active = active + 1 end end
    equal(active, 1, "Only one event tap may remain active after reload")
end)

test("reloading an active script stops its old tap before replacement", function()
    local f = fixture(); local old = f.load()
    equal(old.tap:isEnabled(), true)
    local m = f.load()
    equal(old.tap:isEnabled(), false)
    equal(m.tap:isEnabled(), true)
end)

test("unload disposes resources without changing saved preferences", function()
    local f = fixture(); local m = f.load()
    m.hotkey = hs.hotkey.bind({ "ctrl", "alt", "cmd" }, "D", m.toggle)
    local menu, hotkey = m.menu, m.hotkey
    m.setEnabled(true); m.setOnlyStoppedApps(false)
    local writes = #f.writes
    f.row("Unload script").fn()
    equal(m.tap:isEnabled(), false)
    equal(menu.deleted, true); equal(hotkey.deleted, true)
    equal(#f.writes, writes, "Disposal must not persist disabled state")
    equal(f.saved["dockDoubleClick.enabled"], true)
    equal(f.saved["dockDoubleClick.onlyStoppedApps"], false)
end)

test("different icons and expired timing do not count as a double click", function()
    local f = fixture(); f.load(); f.click(1)
    f.target = f.app(false, "file:///Applications/Different.app")
    equal(f.send("leftMouseDown", 1.2), true)
    equal(f.send("leftMouseUp", 1.25), true)
    equal(f.send("leftMouseDown", 2), true)
end)

test("double click requires positions within six points", function()
    local f = fixture(); f.load(); f.click(1)
    equal(f.send("leftMouseDown", 1.2, { x = 6, clicks = 2 }), false)
    local far = fixture(); far.load(); far.click(1)
    equal(far.send("leftMouseDown", 1.2, { x = 7, clicks = 2 }), true)
end)

test("long holds remain swallowed and cannot make the next click launch", function()
    local f = fixture(); f.load()
    equal(f.send("leftMouseDown", 1), true)
    equal(f.send("leftMouseUp", 1.8), true)
    equal(f.send("leftMouseDown", 1.9), true)
    equal(f.send("leftMouseUp", 1.95), true)
    equal(f.send("leftMouseDown", 2.1, { clicks = 2 }), false)
end)

test("scroll flags and other buttons cancel even while a press is held", function()
    for _, kind in ipairs({ "scrollWheel", "flagsChanged", "rightMouseDown", "otherMouseDown" }) do
        local f = fixture(); f.load()
        equal(f.send("leftMouseDown", 1), true)
        equal(f.send(kind, 1.02), false)
        equal(f.send("leftMouseUp", 1.05), true)
        equal(f.send("leftMouseDown", 1.2, { clicks = 2 }), true,
            kind .. " must prevent mouse-up from rearming the cancelled gesture")
    end
end)

test("mode changes cancel both pending and held gesture recognition", function()
    local f = fixture(); local m = f.load(); f.click(1)
    m.setOnlyStoppedApps(false)
    equal(f.send("leftMouseDown", 1.2), true)
    local held = fixture(); local heldModule = held.load()
    equal(held.send("leftMouseDown", 1), true)
    heldModule.setOnlyStoppedApps(false)
    equal(held.send("leftMouseUp", 1.05), true)
    equal(held.send("leftMouseDown", 1.2, { clicks = 2 }), true)
end)

test("disabling while held completes swallowed pair before stopping tap", function()
    local f = fixture(); local m = f.load()
    equal(f.send("leftMouseDown", 1), true)
    m.setEnabled(false)
    equal(m.enabled, false)
    equal(f.send("leftMouseUp", 1.05), true)
    equal(m.tap:isEnabled(), false)
    m.setEnabled(true)
    equal(f.send("leftMouseDown", 1.2, { clicks = 2 }), true)
end)

test("drag beyond six points replays one tagged down and drag pair", function()
    local f = fixture(); f.load()
    equal(f.send("leftMouseDown", 1), true)
    equal(f.send("leftMouseDragged", 1.02, { x = 6 }), true)
    local suppressed, replay = f.send("leftMouseDragged", 1.03, { x = 7 })
    equal(suppressed, true); equal(type(replay), "table"); equal(#replay, 2)
    equal(replay[1]:getType(), T.leftMouseDown)
    equal(replay[2]:getType(), T.leftMouseDragged)
    local tag = replay[1]:getProperty(P.eventSourceUserData)
    truthy(tag ~= 0, "Replay must carry a bypass tag")
    equal(replay[2]:getProperty(P.eventSourceUserData), tag)
    equal(replay[1]:getProperty(P.mouseEventClickState), 1)
    equal(replay[2]:getProperty(P.mouseEventClickState), 1)
    equal(f.module.tap.callback(replay[1]), false)
    equal(f.module.tap.callback(replay[2]), false)
    local nextSuppressed, nextReplay = f.send("leftMouseDragged", 1.04, { x = 10 })
    equal(nextSuppressed, false); equal(nextReplay, nil)
    equal(f.send("leftMouseUp", 1.08, { x = 10 }), false)
    equal(f.send("leftMouseDown", 1.2), true, "Dragging must not arm a second click")
end)

test("non-app Dock tiles modified clicks and unavailable AX pass through", function()
    for _, subrole in ipairs({ "AXFolderDockItem", "AXTrashDockItem", "AXMinimizedWindowDockItem" }) do
        local f = fixture(); f.target = f.app(false, nil, subrole); f.load()
        equal(f.send("leftMouseDown", 1), false)
        equal(f.send("leftMouseUp", 1.05), false)
    end
    for _, modifier in ipairs({ "cmd", "alt", "ctrl", "shift", "fn" }) do
        local f = fixture(); f.load()
        equal(f.send("leftMouseDown", 1, { flags = { [modifier] = true } }), false)
    end
    local missing = fixture(); missing.target = nil; missing.load()
    equal(missing.send("leftMouseDown", 1), false)
    local timeout = fixture(); timeout.failDockTimeout = true; timeout.load()
    equal(timeout.send("leftMouseDown", 1), false)
end)

test("unexpected callback errors fail open and stop actual tap", function()
    local f = fixture(); local m = f.load(); f.throwAX = true
    equal(f.send("leftMouseDown", 1), false)
    equal(m.tap:isEnabled(), false)
    truthy(type(m.lastError) == "string" and #m.lastError > 0)
    equal(m.enabled, true, "A transient tap error must retain desired Enabled state")
    f.throwAX = false
    f.row("Retry").fn()
    equal(m.tap:isEnabled(), true)
end)

print(string.format("%d assertions across %d cases; %d failed cases", assertions, cases, failures))
if failures > 0 then os.exit(1) end
