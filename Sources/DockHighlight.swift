import AppKit
import QuartzCore

/// The event-tap thread reads only this immutable geometry, never the AppKit window.
struct HighlightSnapshot: Equatable {
    let generation: UInt64
    let windowNumber: Int
    let frame: CGRect
}

private final class HighlightPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Briefly dims the app icon's alpha silhouette, then fades the dimming away.
/// All AppKit rendering and cache access stay on the main thread; icon loading does not.
final class DockHighlight {
    private let snapshotLock = NSLock()
    private var visibleSnapshot: HighlightSnapshot?
    private var panel: HighlightPanel?
    private var dimLayer: CALayer?
    private var dimMask: CALayer?
    private var dismissal: DispatchWorkItem?
    private var generation: UInt64 = 0
    private let duration: TimeInterval = 0.56
    private let padding: CGFloat = 4
    private let dockPreferences = UserDefaults(suiteName: "com.apple.dock")
    private let iconQueue = DispatchQueue(label: "Dockmal.icon-mask", qos: .userInitiated)
    private var iconCache: [String: CGImage] = [:]
    private var iconCacheOrder: [String] = []
    private let iconCacheLimit = 32

    func snapshot() -> HighlightSnapshot? {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return visibleSnapshot
    }

    /// Receives AX/CG global coordinates and a system-uptime deadline for showing feedback.
    func show(frame: CGRect, appURL: URL?, expiresAt: TimeInterval) {
        precondition(Thread.isMainThread)
        hide()
        let values = [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height]
        guard values.allSatisfy({ $0.isFinite }),
              frame.size.width >= 8, frame.size.height >= 8,
              frame.size.width <= 512, frame.size.height <= 512,
              abs(frame.origin.x) < 1_000_000, abs(frame.origin.y) < 1_000_000,
              expiresAt.isFinite, ProcessInfo.processInfo.systemUptime < expiresAt else { return }
        let requestGeneration = generation
        guard let appURL, appURL.isFileURL, appURL.pathExtension.lowercased() == "app" else {
            return
        }
        let path = appURL.standardizedFileURL.path
        if let cached = iconCache[path] {
            touchCachedIcon(path)
            present(frame: frame, maskImage: cached, expiresAt: expiresAt, generation: requestGeneration)
            return
        }

        iconQueue.async { [weak self] in
            // A queued request may already have expired before any filesystem work starts.
            guard ProcessInfo.processInfo.systemUptime < expiresAt else { return }
            let maskImage: CGImage? = autoreleasepool {
                guard FileManager.default.fileExists(atPath: path),
                      let image = NSWorkspace.shared.icon(forFile: path).copy() as? NSImage else { return nil }
                image.size = NSSize(width: 256, height: 256)
                var proposedRect = CGRect(x: 0, y: 0, width: 256, height: 256)
                return image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let maskImage { self.cacheIcon(maskImage, for: path) }
                // A second click, a setting change or another feedback request can invalidate this lookup.
                guard let maskImage, self.generation == requestGeneration,
                      ProcessInfo.processInfo.systemUptime < expiresAt else { return }
                self.present(frame: frame, maskImage: maskImage, expiresAt: expiresAt,
                             generation: requestGeneration)
            }
        }
    }

    private func present(frame: CGRect, maskImage: CGImage, expiresAt: TimeInterval,
                         generation requestGeneration: UInt64) {
        precondition(Thread.isMainThread)
        guard generation == requestGeneration,
              ProcessInfo.processInfo.systemUptime < expiresAt,
              let primaryScreen = NSScreen.screens.first,
              let orientation = DockOrientation(rawValue: dockPreferences?.string(forKey: "orientation") ?? "bottom"),
              let iconFrame = DockIconGeometry.iconCanvas(in: frame, orientation: orientation) else { return }
        let overlayFrame = frame.insetBy(dx: -padding, dy: -padding)
        let windowFrame = CGRect(x: overlayFrame.minX,
                                 y: primaryScreen.frame.maxY - overlayFrame.maxY,
                                 width: overlayFrame.width, height: overlayFrame.height)
        let window = makePanelIfNeeded()
        guard let content = window.contentView, let layer = content.layer,
              let dimLayer, let dimMask else { return }
        window.setFrame(windowFrame, display: false)
        let bounds = content.bounds
        let screenIconFrame = CGRect(x: iconFrame.minX,
                                     y: primaryScreen.frame.maxY - iconFrame.maxY,
                                     width: iconFrame.width, height: iconFrame.height)
        // AppKit may round the panel's origin. Convert the original screen rect
        // through its actual window/content coordinates to preserve fractional offsets.
        let iconBounds = content.convert(window.convertFromScreen(screenIconFrame), from: nil)
        let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = bounds
        layer.contentsScale = window.backingScaleFactor
        layer.opacity = reducedMotion ? 1 : 0
        dimLayer.frame = iconBounds
        dimMask.frame = CGRect(origin: .zero, size: iconBounds.size)
        dimMask.contents = maskImage
        dimMask.contentsScale = window.backingScaleFactor
        if !reducedMotion {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = duration
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(fade, forKey: "feedbackFade")
        }
        CATransaction.commit()

        // Non-deferred creation allocates the window before ordering it on screen.
        // Never show an untracked panel or an effect whose lookup/setup missed its deadline.
        let windowNumber = window.windowNumber
        guard windowNumber > 0, generation == requestGeneration,
              ProcessInfo.processInfo.systemUptime < expiresAt else {
            removeAnimations(from: layer)
            return
        }
        let actualWindowFrame = window.frame
        let actualOverlayFrame = CGRect(x: actualWindowFrame.minX,
                                        y: primaryScreen.frame.maxY - actualWindowFrame.maxY,
                                        width: actualWindowFrame.width, height: actualWindowFrame.height)
        setSnapshot(HighlightSnapshot(generation: generation, windowNumber: windowNumber,
                                      frame: actualOverlayFrame))
        window.orderFrontRegardless()

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == requestGeneration else { return }
            self.hide()
        }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func hide() {
        precondition(Thread.isMainThread)
        generation &+= 1
        dismissal?.cancel()
        dismissal = nil
        removeAnimations(from: panel?.contentView?.layer)
        panel?.orderOut(nil)
        setSnapshot(nil)
    }

    private func cacheIcon(_ image: CGImage, for path: String) {
        iconCache[path] = image
        touchCachedIcon(path)
        while iconCacheOrder.count > iconCacheLimit {
            iconCache.removeValue(forKey: iconCacheOrder.removeFirst())
        }
    }

    private func touchCachedIcon(_ path: String) {
        iconCacheOrder.removeAll { $0 == path }
        iconCacheOrder.append(path)
    }

    private func removeAnimations(from layer: CALayer?) {
        layer?.removeAllAnimations()
        for child in layer?.sublayers ?? [] { removeAnimations(from: child) }
        if let mask = layer?.mask { removeAnimations(from: mask) }
    }

    private func setSnapshot(_ value: HighlightSnapshot?) {
        snapshotLock.lock()
        visibleSnapshot = value
        snapshotLock.unlock()
    }

    private func makePanelIfNeeded() -> HighlightPanel {
        if let panel { return panel }
        let window = HighlightPanel(contentRect: .zero,
                                    styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = true
        window.animationBehavior = .none
        window.isExcludedFromWindowsMenu = true
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        // AX exclusion is descriptive only; hit testing still accounts for this window.
        window.setAccessibilityElement(false)
        window.setAccessibilityChildren([])

        let content = NSView(frame: .zero)
        content.setAccessibilityElement(false)
        content.setAccessibilityChildren([])
        let layer = CALayer()
        layer.backgroundColor = NSColor.clear.cgColor
        // This view hosts our layer: assign it before enabling layer hosting so
        // AppKit does not manage the geometry of a replacement backing layer.
        content.layer = layer
        content.wantsLayer = true
        window.contentView = content

        let dimLayer = CALayer()
        dimLayer.backgroundColor = NSColor.black.cgColor
        dimLayer.opacity = 0.35
        let dimMask = CALayer()
        dimMask.contentsGravity = .resizeAspect
        dimLayer.mask = dimMask
        layer.addSublayer(dimLayer)

        self.dimLayer = dimLayer
        self.dimMask = dimMask
        panel = window
        return window
    }
}
