import AppKit
import ApplicationServices

struct DockApplication {
    let id: String
    let isRunning: Bool?
    let frame: CGRect?
    let appURL: URL?
}

/// Only the event-tap thread uses this object. No AX actions or preferences are written.
final class DockHitTester {
    private let system = AXUIElementCreateSystemWide()
    private let highlightSnapshot: () -> HighlightSnapshot?
    private var previousElement: AXUIElement?
    private var previousKey = ""
    private var nextKey = 0
    private let timeout: Float = 0.012

    init(highlightSnapshot: @escaping () -> HighlightSnapshot? = { nil }) {
        self.highlightSnapshot = highlightSnapshot
        AXUIElementSetMessagingTimeout(system, timeout)
    }

    func reset() {
        previousElement = nil
        previousKey = ""
    }

    func application(at point: CGPoint, dockPID: pid_t) -> DockApplication? {
        guard dockPID > 0 else { return nil }
        let started = ProcessInfo.processInfo.systemUptime
        let windows = Self.windowSnapshot()
        guard OverlayHitPolicy.mayHitDock(at: point, dockPID: dockPID, windows: windows),
              ProcessInfo.processInfo.systemUptime - started < 0.025 else { return nil }
        var hit: AXUIElement?
        // System-wide hit testing respects the topmost window, including overlays.
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
              var element = hit else { return nil }
        var owner: pid_t = 0
        guard AXUIElementGetPid(element, &owner) == .success,
              ProcessInfo.processInfo.systemUptime - started < 0.025 else { return nil }

        var usedSnapshot: HighlightSnapshot?
        if owner != dockPID {
            guard owner == getpid(), let snapshot = highlightSnapshot(),
                  snapshot.frame.contains(point),
                  let rawWindows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                              kCGNullWindowID) as? [[String: Any]],
                  highlightSnapshot() == snapshot,
                  ProcessInfo.processInfo.systemUptime - started < 0.025 else { return nil }
            let windows = rawWindows.map(Self.windowInfo)
            guard OverlayHitPolicy.allowsDockFallback(at: point,
                      overlayWindowNumber: snapshot.windowNumber, overlayFrame: snapshot.frame,
                      ownPID: getpid(), dockPID: dockPID, windows: windows),
                  highlightSnapshot() == snapshot,
                  ProcessInfo.processInfo.systemUptime - started < 0.025 else { return nil }

            let dock = AXUIElementCreateApplication(dockPID)
            AXUIElementSetMessagingTimeout(dock, timeout)
            var dockHit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(dock, Float(point.x), Float(point.y), &dockHit) == .success,
                  let dockElement = dockHit,
                  AXUIElementGetPid(dockElement, &owner) == .success, owner == dockPID,
                  highlightSnapshot() == snapshot,
                  ProcessInfo.processInfo.systemUptime - started < 0.025 else { return nil }
            element = dockElement
            usedSnapshot = snapshot
        }

        AXUIElementSetMessagingTimeout(element, timeout)
        let names = [kAXRoleAttribute, kAXSubroleAttribute, kAXURLAttribute,
                     kAXIsApplicationRunningAttribute, kAXPositionAttribute, kAXSizeAttribute] as CFArray
        var rawValues: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names, [], &rawValues) == .success,
              let values = rawValues as? [Any], values.count == 6,
              values[0] as? String == kAXDockItemRole,
              values[1] as? String == kAXApplicationDockItemSubrole,
              ProcessInfo.processInfo.systemUptime - started < 0.04 else { return nil }
        if let usedSnapshot, highlightSnapshot() != usedSnapshot { return nil }
        let isRunning = values[3] as? Bool
        // Optional visual metadata must never determine whether a Dock click is filtered.
        let frame = DockIconGeometry.frame(position: Self.pointValue(values[4]),
                                           size: Self.sizeValue(values[5]), containing: point)
        let appURL = DockIconGeometry.localAppURL(values[2])

        if let url = values[2] as? URL {
            return DockApplication(id: "\(dockPID):\(url.absoluteString)", isRunning: isRunning, frame: frame, appURL: appURL)
        }
        if let url = values[2] as? String, !url.isEmpty {
            return DockApplication(id: "\(dockPID):\(url)", isRunning: isRunning, frame: frame, appURL: appURL)
        }
        // Some Dock items expose no URL. Compare AX identity, never localized titles.
        if let previousElement, CFEqual(previousElement, element) {
            return DockApplication(id: previousKey, isRunning: isRunning, frame: frame, appURL: appURL)
        }
        nextKey += 1
        previousElement = element
        previousKey = "\(dockPID):ax:\(nextKey)"
        return DockApplication(id: previousKey, isRunning: isRunning, frame: frame, appURL: appURL)
    }

    private static func pointValue(_ raw: Any) -> CGPoint? {
        guard CFGetTypeID(raw as CFTypeRef) == AXValueGetTypeID() else { return nil }
        let value = raw as! AXValue
        guard AXValueGetType(value) == .cgPoint else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    private static func sizeValue(_ raw: Any) -> CGSize? {
        guard CFGetTypeID(raw as CFTypeRef) == AXValueGetTypeID() else { return nil }
        let value = raw as! AXValue
        guard AXValueGetType(value) == .cgSize else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }

    private static func windowInfo(_ raw: [String: Any]) -> OverlayWindowInfo {
        let frame = (raw[kCGWindowBounds as String] as? [String: Any])
            .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
        return OverlayWindowInfo(number: (raw[kCGWindowNumber as String] as? NSNumber)?.intValue,
                                 ownerPID: (raw[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                                 frame: frame,
                                 alpha: (raw[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
                                 isOnscreen: (raw[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue)
    }

    private static func windowSnapshot() -> [OverlayWindowInfo]? {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                  kCGNullWindowID) as? [[String: Any]] else { return nil }
        return raw.map(windowInfo)
    }

}
