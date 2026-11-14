import AppKit
import ApplicationServices
import ServiceManagement

private let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"

// Safe executable smoke check: no app instance, event tap, permission prompt or writes.
if CommandLine.arguments.contains("--check") {
    print("Dockmal \(appVersion)")
    print("Accessibility: \(AXIsProcessTrusted() ? "granted" : "not granted")")
    print("Diagnostics only; event interception is not running.")
    exit(0)
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var filter: EventFilter?
    private var generation = UUID()
    private var permissionTimer: Timer?
    private var mayStart = true
    private var suspended = false
    private var hadPermission = false
    private var statusMessage = ""
    private var statusReady = false
    private var observers: [NSObjectProtocol] = []
    private let workspaceCenter = NSWorkspace.shared.notificationCenter
    private let preferences = UserDefaults.standard
    private let loginItem = SMAppService.mainApp
    private let highlight = DockHighlight()
    private var filterEnabled: Bool {
        get { preferences.bool(forKey: "filterEnabled") }
        set { preferences.set(newValue, forKey: "filterEnabled") }
    }
    private var onlyAppsNotRunning: Bool {
        get { preferences.bool(forKey: "onlyAppsNotRunning") }
        set { preferences.set(newValue, forKey: "onlyAppsNotRunning") }
    }
    private var activeStatusMessage: String {
        onlyAppsNotRunning ? "Double-click to launch; single-click for running apps" : "Double-click for all Dock app icons"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil)
            return
        }
        preferences.register(defaults: ["filterEnabled": true, "onlyAppsNotRunning": true])
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        showStatus(filterEnabled ? "Waiting for Accessibility permission" : "Disabled", ready: false)
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.suspended = true
                self.stopFilter()
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.suspended = false
                self.mayStart = true
                self.refresh()
            })
        }
        permissionTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(permissionTimer!, forMode: .common)
        if filterEnabled && !AXIsProcessTrusted() {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
        refresh()
    }

    private func configure(_ filter: EventFilter) {
        let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
            .first?.processIdentifier ?? 0
        filter.configure(dockPID: pid, interval: NSEvent.doubleClickInterval,
                         mode: onlyAppsNotRunning ? .appsNotRunning : .allApps)
    }

    private func refresh() {
        guard filterEnabled else {
            if filter != nil { stopFilter() }
            showStatus("Disabled", ready: false)
            return
        }
        guard !suspended else { return }
        let trusted = AXIsProcessTrusted()
        if !trusted {
            if filter != nil { stopFilter() }
            hadPermission = false
            showStatus("Accessibility permission is required", ready: false)
            mayStart = true
            return
        }
        if !hadPermission { mayStart = true }
        hadPermission = true
        if let filter {
            configure(filter)
            return
        }
        guard mayStart else { return }
        mayStart = false
        generation = UUID()
        let currentGeneration = generation
        let next = EventFilter(highlightSnapshot: { [highlight] in highlight.snapshot() },
                              feedback: { [weak self] feedback in
            guard let self, self.generation == currentGeneration else { return }
            switch feedback {
            case .show(let frame, let appURL, let expiresAt):
                guard self.filterEnabled, !self.suspended,
                      ProcessInfo.processInfo.systemUptime < expiresAt else {
                    self.highlight.hide()
                    return
                }
                self.highlight.show(frame: frame, appURL: appURL, expiresAt: expiresAt)
            case .hide:
                self.highlight.hide()
            }
        }) { [weak self] status in
            guard let self, self.generation == currentGeneration else { return }
            switch status {
            case .active:
                self.showStatus(self.activeStatusMessage, ready: true)
            case .failed(let message):
                self.highlight.hide()
                self.filter = nil
                self.showStatus(message, ready: false)
            }
        }
        filter = next
        configure(next)
        showStatus("Starting…", ready: false)
        next.start()
    }

    private func showStatus(_ message: String, ready: Bool) {
        guard message != statusMessage || ready != statusReady || statusItem.menu == nil else { return }
        statusMessage = message
        statusReady = ready
        let isNormalState = ready || !filterEnabled
        let symbol = isNormalState ? "2.brakesignal" : "exclamationmark.circle"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Dockmal")
            ?? (isNormalState
                ? NSImage(systemSymbolName: "computermouse", accessibilityDescription: "Dockmal")
                : nil)
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = "Dockmal — \(message)"
        rebuildMenu()
    }

    private func addSettingsItems(to menu: NSMenu) {
        let enabled = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        enabled.target = self
        enabled.state = filterEnabled ? .on : .off
        menu.addItem(enabled)
        let mode = NSMenuItem(title: "Only for apps not running", action: #selector(toggleMode), keyEquivalent: "")
        mode.target = self
        mode.state = onlyAppsNotRunning ? .on : .off
        mode.isEnabled = filterEnabled
        menu.addItem(mode)
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        // Otherwise AppKit may re-enable the mode item because its action exists.
        menu.autoenablesItems = false
        menu.delegate = self
        populateMenu(menu)
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Read current OS state even when filtering is disabled or Settings changed it.
        populateMenu(menu)
    }

    private func addInformation(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func populateMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        addSettingsItems(to: menu)
        menu.addItem(.separator())

        let loginStatus = loginItem.status
        let autostart = NSMenuItem(title: "Autostart", action: #selector(toggleAutostart), keyEquivalent: "")
        autostart.target = self
        switch loginStatus {
        case .enabled:
            autostart.state = .on
        case .requiresApproval:
            autostart.state = .mixed
            autostart.toolTip = "Approval is required in Login Items Settings. Click to cancel Autostart."
        default:
            autostart.state = .off
        }
        menu.addItem(autostart)
        addInformation("A11y: \(AXIsProcessTrusted() ? "granted" : "not granted")", to: menu)
        addInformation("Version: \(appVersion)", to: menu)
        if loginStatus == .requiresApproval {
            let approval = NSMenuItem(title: "Open Login Items Settings…", action: #selector(openLoginItems), keyEquivalent: "")
            approval.target = self
            menu.addItem(approval)
        }
        menu.addItem(.separator())
        if filterEnabled && !statusReady {
            let state = NSMenuItem(title: statusMessage, action: nil, keyEquivalent: "")
            state.isEnabled = false
            menu.addItem(state)
            let permissions = NSMenuItem(title: "Open Accessibility Settings…", action: #selector(openPermissions), keyEquivalent: "")
            permissions.target = self
            menu.addItem(permissions)
            if hadPermission {
                let retry = NSMenuItem(title: "Retry", action: #selector(retry), keyEquivalent: "")
                retry.target = self
                menu.addItem(retry)
            }
            menu.addItem(.separator())
        }
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func toggleAutostart() {
        do {
            switch loginItem.status {
            case .enabled, .requiresApproval:
                try loginItem.unregister()
            default:
                try loginItem.register()
            }
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Could not update Autostart"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        rebuildMenu()
    }

    @objc private func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    @objc private func toggleEnabled() {
        filterEnabled.toggle()
        stopFilter()
        mayStart = true
        if filterEnabled {
            showStatus(suspended ? "Waiting for the session to become active" : "Starting…", ready: false)
            refresh()
        } else {
            showStatus("Disabled", ready: false)
        }
    }

    @objc private func toggleMode() {
        guard filterEnabled else { return }
        highlight.hide()
        onlyAppsNotRunning.toggle()
        if let filter { configure(filter) }
        if statusReady {
            showStatus(activeStatusMessage, ready: true)
        } else {
            rebuildMenu()
        }
    }

    @objc private func openPermissions() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func retry() {
        stopFilter()
        mayStart = true
        refresh()
    }

    private func stopFilter() {
        generation = UUID()
        highlight.hide()
        filter?.stop()
        filter = nil
    }

    @objc private func quit() { NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        permissionTimer?.invalidate()
        for observer in observers { workspaceCenter.removeObserver(observer) }
        stopFilter()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
