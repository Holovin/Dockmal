-- Dock Double Click for Hammerspoon 1.1.x / Lua 5.4. Version 0.2.1.
--
-- Copy this file to ~/.hammerspoon/dock_double_click.lua and load it once:
--   dofile(hs.configdir .. "/dock_double_click.lua")
-- Quit the standalone Dock Double Click app before enabling this alternative.
--
-- Menu (D²): Enabled / Only for apps not running / Unload script.
-- Both checkboxes default to true. Choices persist in hs.settings.
-- Running apps: normal single click. Stopped apps: double click to launch.
-- Uncheck the second item to require a double click for every application.
-- Unload script stops only this script, not Hammerspoon or other automations.
-- dockDoubleClick.toggle() toggles Enabled; dockDoubleClick.status() reports state.
-- No global hotkey is registered; assign one explicitly if needed.
--
-- Right/modified clicks, folders, Trash and minimized windows pass through.
-- A captured first down/up is swallowed. The second pair is passed to Dock
-- as a single click. Movement over 6 points hands a captured drag back to Dock.
-- Long left-button holds on filtered icons are swallowed; use right-click.
-- AX errors/unknown running state fail open. No Dock preferences are changed.
-- Real Dock hit-testing and drag replay still require a manual Mac test.

local previous = rawget(_G, "dockDoubleClick")
if previous then
    if previous.dispose then
        previous.dispose()
    else
        -- Upgrade from the original script without leaving its tap alive.
        previous.stop()
        if previous.tap then previous.tap:stop() end
        if previous.hotkey then previous.hotkey:delete() end
        if previous.inspectTimer then previous.inspectTimer:stop() end
        if previous.menu then previous.menu:delete() end
    end
end

local ENABLED_KEY = "dockDoubleClick.enabled"
local MODE_KEY = "dockDoubleClick.onlyStoppedApps"
local function setting(key, default)
    local value = hs.settings.get(key)
    if type(value) == "boolean" then return value end
    return default
end

local M = {
    config = {
        onlyStoppedApps = setting(MODE_KEY, true),
        interval = nil, -- nil uses the system double-click interval
        dragThreshold = 6,
        axTimeout = 0.012,
        debug = false,
    },
    enabled = setting(ENABLED_KEY, true),
    stats = { blocked = 0, accepted = 0, drags = 0 },
}
_G.dockDoubleClick = M

local T, P = hs.eventtap.event.types, hs.eventtap.event.properties
local REPLAY_TAG = 0x44444331
local pressed, pending, dockAX, dockPID
local disposed = false

local function log(message)
    if M.config.debug then print("[DockDoubleClick] " .. message) end
end

local function updateUI()
    if not M.menu then return end
    local text
    if not M.enabled then
        text = "Disabled"
    elseif not M.tap:isEnabled() then
        text = M.lastError or "Click filtering is not running"
    elseif M.config.onlyStoppedApps then
        text = "Double-click to launch; single-click for running apps"
    else
        text = "Double-click for all Dock app icons"
    end
    M.menu:setTitle("D²")
    M.menu:setTooltip("Dock Double Click — " .. text)
end

local function modified(event)
    local f = event:getFlags()
    return f.cmd or f.alt or f.ctrl or f.shift or f.fn
end

local function distanceSquared(a, b)
    return (a.x - b.x)^2 + (a.y - b.y)^2
end

local function eventSeconds(event)
    local ns = event:timestamp()
    if ns == 0 then ns = hs.timer.absoluteTime() end
    return ns / 1e9
end

local function cancelPending()
    pending = nil
    if pressed and not pressed.pass then pressed.cancelled = true end
end

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function topmostWindowIsDock(point, pid)
    if not finite(point.x) or not finite(point.y) or not finite(pid) or pid <= 0 then
        return false
    end
    -- true keeps Dock and higher-level windows in the front-to-back CGWindow list.
    -- This does not query another app through AX or alter Hammerspoon's AX timeout.
    local windows = hs.window.list(true)
    if type(windows) ~= "table" then return false end
    for _, window in ipairs(windows) do
        if type(window) ~= "table" then return false end
        if window.kCGWindowIsOnscreen ~= false and window.kCGWindowAlpha ~= 0 then
            local bounds = window.kCGWindowBounds
            local alpha, owner = window.kCGWindowAlpha, window.kCGWindowOwnerPID
            if window.kCGWindowIsOnscreen ~= true
                or not finite(alpha) or alpha <= 0 or alpha > 1
                or type(bounds) ~= "table"
                or not finite(bounds.X) or not finite(bounds.Y)
                or not finite(bounds.Width) or bounds.Width <= 0
                or not finite(bounds.Height) or bounds.Height <= 0
                or not finite(bounds.X + bounds.Width)
                or not finite(bounds.Y + bounds.Height) then
                return false
            end
            if point.x >= bounds.X and point.x < bounds.X + bounds.Width
                and point.y >= bounds.Y and point.y < bounds.Y + bounds.Height then
                return finite(owner) and owner > 0 and owner == pid
            end
        end
    end
    return false
end

local function dockItemAt(point)
    local app = hs.application.applicationsForBundleID("com.apple.dock")[1]
    if not app then
        dockAX, dockPID, pending = nil, nil, nil
        return nil
    end
    local pid = app:pid()
    if not dockAX or dockPID ~= pid then
        pending = nil
        dockAX = hs.axuielement.applicationElement(app)
        dockPID = pid
        -- A system-wide timeout would affect other Hammerspoon scripts.
        -- Only change this Dock AX reference and the individual hit element.
        if not dockAX or not dockAX:setTimeout(M.config.axTimeout) then
            dockAX = nil
            return nil
        end
    end
    -- An application-scoped AX lookup alone can see an icon behind a foreign panel.
    -- Capture only when the global window stack identifies Dock at this point.
    if not topmostWindowIsDock(point, pid) then return nil end
    local element, err = dockAX:elementAtPosition(point)
    if not element then
        if err then M.lastAXError = err end
        return nil
    end
    if not element:setTimeout(M.config.axTimeout) then return nil end
    if element:attributeValue("AXRole") ~= "AXDockItem"
        or element:attributeValue("AXSubrole") ~= "AXApplicationDockItem" then
        return nil
    end
    local url = element:attributeValue("AXURL")
    local key
    if type(url) == "table" then key = url.filePath or url.url
    elseif type(url) == "string" then key = url end
    return { element = element, key = key, pid = pid }
end

local function sameItem(a, b)
    if a.pid ~= b.pid then return false end
    if a.key and b.key then return a.key == b.key end
    return a.element == b.element
end

local function normalize(event)
    event:setProperty(P.mouseEventClickState, 1)
    return event
end

local function handle(event)
    if event:getProperty(P.eventSourceUserData) == REPLAY_TAG then return false end
    local kind = event:getType()
    if kind == T.rightMouseDown or kind == T.otherMouseDown
        or kind == T.scrollWheel or kind == T.flagsChanged then
        cancelPending()
        return false
    end

    -- Ownership of mouse-up follows its down, not a second hit test.
    if kind == T.leftMouseUp then
        local current = pressed
        pressed = nil
        if not M.enabled then M.tap:stop() end
        if not current then return false end
        if current.pass then normalize(event); return false end
        local now = eventSeconds(event)
        if M.enabled and not current.cancelled and not modified(event)
            and now >= current.time and now - current.time <= current.interval
            and distanceSquared(current.point, event:location()) <= M.config.dragThreshold^2 then
            pending = current
        else
            pending = nil
        end
        return true
    end

    if kind == T.leftMouseDragged then
        if not pressed then return false end
        if pressed.pass then normalize(event); return false end
        if distanceSquared(pressed.point, event:location()) <= M.config.dragThreshold^2 then
            return true
        end
        pending = nil
        local savedDown = normalize(pressed.down:copy())
        local drag = normalize(event:copy())
        savedDown:setProperty(P.eventSourceUserData, REPLAY_TAG)
        drag:setProperty(P.eventSourceUserData, REPLAY_TAG)
        savedDown:timestamp(math.max(0, event:timestamp() - 1))
        pressed.pass = true
        M.stats.drags = M.stats.drags + 1
        return true, { savedDown, drag }
    end

    if kind ~= T.leftMouseDown then return false end
    pressed = nil
    if not M.enabled then
        pending = nil
        M.tap:stop()
        return false
    end
    if modified(event) then pending = nil; return false end
    local point = event:location()
    local item = dockItemAt(point)
    if not item then pending = nil; return false end
    -- Unknown state must not turn a normal activation into a blocked click.
    if M.config.onlyStoppedApps
        and item.element:attributeValue("AXIsApplicationRunning") ~= false then
        pending = nil
        return false
    end
    local now = eventSeconds(event)
    local interval = M.config.interval or hs.eventtap.doubleClickInterval()
    local isDouble = pending and sameItem(pending.item, item)
        and now >= pending.time and now - pending.time <= interval
        and distanceSquared(pending.point, point) <= M.config.dragThreshold^2
    pending = nil
    if isDouble then
        pressed = { pass = true }
        M.stats.accepted = M.stats.accepted + 1
        log("Accepted double-click: " .. (item.key or "Dock app"))
        normalize(event)
        return false
    end
    pressed = { item = item, point = point, time = now, interval = interval, down = event:copy() }
    M.stats.blocked = M.stats.blocked + 1
    log("Blocked first click: " .. (item.key or "Dock app"))
    return true
end

M.tap = hs.eventtap.new({
    T.leftMouseDown, T.leftMouseUp, T.leftMouseDragged,
    T.rightMouseDown, T.otherMouseDown, T.scrollWheel, T.flagsChanged,
}, function(event)
    local ok, suppress, extra = pcall(handle, event)
    if ok then return suppress, extra end
    M.lastError = "Click filtering stopped after an error"
    pending, pressed = nil, nil
    M.tap:stop()
    updateUI()
    print("[DockDoubleClick] " .. tostring(suppress))
    return false
end)

local function activate()
    if disposed then return false end
    -- A draining tap still owns its down/up pair. Re-enabling must not forget it.
    if M.tap:isEnabled() then
        M.lastError = nil
        updateUI()
        return true
    end
    if not hs.accessibilityState(true) then
        M.lastError = "Accessibility permission is required"
        updateUI()
        return false
    end
    pending, pressed, dockAX, dockPID = nil, nil, nil, nil
    M.lastError = nil
    M.tap:start()
    local active = M.tap:isEnabled()
    if not active then M.lastError = "Could not start click filtering" end
    updateUI()
    return active
end

function M.setEnabled(value)
    assert(type(value) == "boolean", "Enabled must be boolean")
    if disposed then return false end
    local wasEnabled = M.enabled
    M.enabled = value
    hs.settings.set(ENABLED_KEY, value)
    if value then
        if not wasEnabled then cancelPending() end
        return activate()
    end
    cancelPending()
    -- Finish an already captured down/up pair before removing the filter.
    if not pressed then M.tap:stop() end
    updateUI()
    return true
end

function M.setOnlyStoppedApps(value)
    assert(type(value) == "boolean", "Only for apps not running must be boolean")
    if disposed then return end
    M.config.onlyStoppedApps = value
    hs.settings.set(MODE_KEY, value)
    cancelPending()
    updateUI()
end

function M.start() return M.setEnabled(true) end
function M.stop() return M.setEnabled(false) end
function M.toggle()
    M.setEnabled(not M.enabled)
    hs.alert.show("Dock Double Click: " .. (M.enabled and "Enabled" or "Disabled"))
end

function M.status()
    return {
        enabled = M.enabled,
        onlyStoppedApps = M.config.onlyStoppedApps,
        tapRunning = M.tap:isEnabled(),
        accessibility = hs.accessibilityState(),
        blocked = M.stats.blocked,
        accepted = M.stats.accepted,
        drags = M.stats.drags,
        lastError = M.lastError,
        lastAXError = M.lastAXError,
    }
end

function M.inspect()
    if M.inspectTimer then M.inspectTimer:stop() end
    M.inspectTimer = hs.timer.doAfter(3, function()
        M.inspectTimer = nil
        local ok, result = pcall(function()
            local e = hs.axuielement.systemElementAtPosition(hs.mouse.absolutePosition())
            if not e then return { error = "No AX element at pointer" } end
            e:setTimeout(M.config.axTimeout)
            return {
                role = e:attributeValue("AXRole"), subrole = e:attributeValue("AXSubrole"),
                title = e:attributeValue("AXTitle"), url = e:attributeValue("AXURL"),
                running = e:attributeValue("AXIsApplicationRunning"),
            }
        end)
        print("[DockDoubleClick] " .. (ok and hs.inspect(result) or tostring(result)))
    end)
    return "Move the pointer over a Dock app; inspect result in Console in 3 seconds."
end

function M.dispose()
    if disposed then return end
    disposed = true
    M.enabled, pending, pressed = false, nil, nil
    M.tap:stop()
    if M.hotkey then M.hotkey:delete(); M.hotkey = nil end
    if M.inspectTimer then M.inspectTimer:stop(); M.inspectTimer = nil end
    if M.menu then M.menu:delete(); M.menu = nil end
    if rawget(_G, "dockDoubleClick") == M then _G.dockDoubleClick = nil end
    -- Do not overwrite preferences when unloading or replacing the module.
end

M.menu = hs.menubar.new()
if M.menu then
    M.menu:setMenu(function()
        local items = {
            { title = "Enabled", checked = M.enabled, fn = function() M.setEnabled(not M.enabled) end },
            { title = "Only for apps not running", checked = M.config.onlyStoppedApps,
              disabled = not M.enabled, fn = function()
                  if M.enabled then M.setOnlyStoppedApps(not M.config.onlyStoppedApps) end
              end },
        }
        if M.enabled and not M.tap:isEnabled() then
            items[#items + 1] = { title = "-" }
            items[#items + 1] = { title = M.lastError or "Click filtering is not running", disabled = true }
            items[#items + 1] = { title = "Retry", fn = M.start }
        end
        items[#items + 1] = { title = "-" }
        items[#items + 1] = { title = "Unload script", fn = M.dispose }
        return items
    end)
end
if M.enabled then activate() end
updateUI()
return M
