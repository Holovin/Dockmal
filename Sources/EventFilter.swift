import AppKit
import ApplicationServices
import os.log

enum FilterStatus {
    case active
    case stopped
    case failed(String)
}

enum ClickFeedback {
    case show(frame: CGRect, appURL: URL?, expiresAt: TimeInterval)
    case hide
}

/// Owns one event tap on a dedicated run loop. Gesture and AX state stay on that thread.
final class EventFilter {
    private let lock = NSLock()
    private var workerRunLoop: CFRunLoop?
    private var stopping = false
    private var dockPID: pid_t = 0
    private var interval: TimeInterval = 0.5
    private var mode = DockClickMode.allApps
    private var tap: CFMachPort?
    private var gate = ClickGate()
    private let hitTester: DockHitTester?
    private let applicationAt: (CGPoint, pid_t) -> DockApplication?
    private let copyEvent: (CGEvent) -> CGEvent?
    private var savedDown: CGEvent?
    private var seenDockPID: pid_t = 0
    private var seenMode = DockClickMode.allApps
    private var timeoutCount = 0
    private var lastTimeout: TimeInterval = 0
    private let report: (FilterStatus) -> Void
    private let feedback: (ClickFeedback) -> Void
    private let scheduleFeedback: (@escaping () -> Void) -> Void
    private var feedbackRevision: UInt64 = 0
    private var feedbackMayBeActive = false
    private var configurationRevision: UInt64 = 0
    private let replayTag: Int64 = 0x44444332

    init(highlightSnapshot: @escaping () -> HighlightSnapshot?,
         feedback: @escaping (ClickFeedback) -> Void,
         applicationAt: ((CGPoint, pid_t) -> DockApplication?)? = nil,
         copyEvent: @escaping (CGEvent) -> CGEvent? = { $0.copy() },
         scheduleFeedback: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
         report: @escaping (FilterStatus) -> Void) {
        if let applicationAt {
            self.hitTester = nil
            self.applicationAt = applicationAt
        } else {
            let hitTester = DockHitTester(highlightSnapshot: highlightSnapshot)
            self.hitTester = hitTester
            self.applicationAt = { point, pid in hitTester.application(at: point, dockPID: pid) }
        }
        self.copyEvent = copyEvent
        self.feedback = feedback
        self.scheduleFeedback = scheduleFeedback
        self.report = report
    }

    func configure(dockPID: pid_t, interval: TimeInterval, mode: DockClickMode) {
        lock.lock()
        let changed = self.dockPID != dockPID || self.mode != mode
        self.dockPID = dockPID
        self.interval = interval
        self.mode = mode
        if changed {
            configurationRevision &+= 1
        }
        let currentConfiguration = configurationRevision
        lock.unlock()
        if changed { emitFeedback(.hide, expectedConfiguration: currentConfiguration) }
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "Dockmal.events"
        thread.start()
    }

    func stop() {
        lock.lock()
        stopping = true
        configurationRevision &+= 1
        feedbackRevision &+= 1
        let loop = workerRunLoop
        lock.unlock()
        if let loop {
            CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) {
                self.gate.cancelForTransition()
                self.savedDown = nil
                // Permission loss or a disabled tap cannot deliver a final up.
                // Do not retain an unusable tap and prevent a later Retry forever.
                let canDrain = AXIsProcessTrusted() && self.tap.map { CGEvent.tapIsEnabled(tap: $0) } == true
                if !self.gate.ownsSuppressedPress || !canDrain { CFRunLoopStop(loop) }
            }
            CFRunLoopWakeUp(loop)
        }
    }

    private func emit(_ status: FilterStatus) {
        DispatchQueue.main.async { [report] in report(status) }
    }

    private func emitFeedback(_ event: ClickFeedback, expectedConfiguration: UInt64? = nil) {
        lock.lock()
        if let expectedConfiguration, expectedConfiguration != configurationRevision {
            lock.unlock()
            return
        }
        // Includes a queued show and asynchronous icon loading, not just visibility.
        switch event {
        case .show: feedbackMayBeActive = true
        case .hide:
            guard feedbackMayBeActive else { lock.unlock(); return }
            feedbackMayBeActive = false
        }
        feedbackRevision &+= 1
        let revision = feedbackRevision
        let shouldStop = stopping
        lock.unlock()
        guard !shouldStop else { return }
        scheduleFeedback { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let isCurrent = !self.stopping && self.feedbackRevision == revision
            self.lock.unlock()
            guard isCurrent else { return }
            self.feedback(event)
        }
    }

    private func run() {
        let kinds: [CGEventType] = [.leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                   .rightMouseDown, .otherMouseDown, .scrollWheel, .flagsChanged]
        let mask = kinds.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard let newTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                            options: .defaultTap, eventsOfInterest: mask,
                                            callback: { proxy, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let filter = Unmanaged<EventFilter>.fromOpaque(context).takeUnretainedValue()
            return filter.handle(proxy: proxy, type: type, event: event)
        }, userInfo: pointer) else {
            emit(.failed("Could not enable click filtering. Check Accessibility permission."))
            return
        }
        tap = newTap
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0) else {
            CFMachPortInvalidate(newTap)
            tap = nil
            emit(.failed("Could not start click filtering."))
            return
        }
        let loop = CFRunLoopGetCurrent()!
        lock.lock()
        workerRunLoop = loop
        let shouldStop = stopping
        lock.unlock()
        if !shouldStop {
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: newTap, enable: true)
            emit(.active)
            CFRunLoopRun()
            CFRunLoopRemoveSource(loop, source, .commonModes)
        }
        CGEvent.tapEnable(tap: newTap, enable: false)
        CFMachPortInvalidate(newTap)
        tap = nil
        savedDown = nil
        gate.reset()
        emitFeedback(.hide)
        lock.lock()
        workerRunLoop = nil
        let wasStopped = stopping
        lock.unlock()
        if wasStopped { emit(.stopped) }
    }

    private func handle(proxy: CGEventTapProxy, type: CGEventType,
                        event: CGEvent) -> Unmanaged<CGEvent>? {
        route(type: type, event: event) { $0.tapPostEvent(proxy) }
    }

    /// The production callback and offline adapter tests use the same routing path.
    /// Tests inject hit testing, copying and the replay sink without starting a tap.
    func route(type: CGEventType, event: CGEvent,
               replayEvent: (CGEvent) -> Void) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            emitFeedback(.hide)
            gate.cancelForTransition()
            savedDown = nil
            hitTester?.reset()
            let now = ProcessInfo.processInfo.systemUptime
            timeoutCount = now - lastTimeout > 10 ? 1 : timeoutCount + 1
            lastTimeout = now
            if type == .tapDisabledByTimeout, timeoutCount < 3, AXIsProcessTrusted(), let tap {
                os_log("Dockmal: event tap timed out; resetting gesture and reenabling")
                CGEvent.tapEnable(tap: tap, enable: true)
            } else {
                emit(.failed("Click filtering paused. Choose Retry."))
                CFRunLoopStop(CFRunLoopGetCurrent())
            }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == replayTag {
            return Unmanaged.passUnretained(event)
        }
        lock.lock()
        let configPID = dockPID
        let configInterval = interval
        let configMode = mode
        let configRevision = configurationRevision
        let shouldStop = stopping
        lock.unlock()
        if shouldStop {
            gate.cancelForTransition()
            savedDown = nil
            let owned = gate.ownsSuppressedPress
            if type == .leftMouseUp || type == .leftMouseDown { gate.reset() }
            if !gate.ownsSuppressedPress, let loop = workerRunLoop { CFRunLoopStop(loop) }
            // A new down also recovers a press whose up was lost while the tap was disabled.
            return owned && (type == .leftMouseUp || type == .leftMouseDragged)
                ? nil : Unmanaged.passUnretained(event)
        }
        if seenDockPID != configPID {
            emitFeedback(.hide)
            seenDockPID = configPID
            gate.cancelForTransition()
            savedDown = nil
            hitTester?.reset()
        }
        if seenMode != configMode {
            emitFeedback(.hide)
            seenMode = configMode
            gate.cancelPendingGesture()
        }
        let point = PointerPoint(x: event.location.x, y: event.location.y)
        let time = event.timestamp == 0 ? ProcessInfo.processInfo.systemUptime : Double(event.timestamp) / 1e9
        let action: ClickAction
        switch type {
        case .leftMouseDown:
            savedDown = nil
            let modifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn]
            let bypass = !event.flags.intersection(modifiers).isEmpty
            let application = bypass ? nil : applicationAt(event.location, configPID)
            let target = configMode.targetID(application?.id, isRunning: application?.isRunning)
            // AX may block while the main thread stops or reconfigures the filter.
            // Commit this down only if its configuration is still current. Keep AX
            // and feedback outside the lock; only the pure gate decision is atomic.
            lock.lock()
            guard !stopping, configurationRevision == configRevision else {
                lock.unlock()
                gate.reset()
                return Unmanaged.passUnretained(event)
            }
            action = gate.mouseDown(targetID: target, at: point, time: time,
                                    interval: configInterval, bypass: bypass)
            lock.unlock()
            // Keep the snapshot stable during hit testing; dismiss only afterwards.
            emitFeedback(.hide, expectedConfiguration: configRevision)
            if action == .suppress {
                savedDown = copyEvent(event)
                if savedDown == nil {
                    gate.reset()
                    return Unmanaged.passUnretained(event)
                }
                // Drop stale UI requests instead of flashing after a busy main loop.
                if let frame = application?.frame {
                    emitFeedback(.show(frame: frame, appURL: application?.appURL,
                                       expiresAt: ProcessInfo.processInfo.systemUptime + 0.15),
                                 expectedConfiguration: configRevision)
                }
            }
        case .leftMouseUp:
            action = gate.mouseUp(at: point, time: time)
            savedDown = nil
        case .leftMouseDragged:
            action = gate.mouseDragged(to: point, time: time)
        default:
            gate.cancelPendingGesture()
            emitFeedback(.hide)
            return Unmanaged.passUnretained(event)
        }
        switch action {
        case .passThrough:
            return Unmanaged.passUnretained(event)
        case .suppress:
            return nil
        case .forwardAsSingleClick:
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            return Unmanaged.passUnretained(event)
        case .beginDrag:
            emitFeedback(.hide)
            guard let down = savedDown, let drag = copyEvent(event) else {
                gate.abortDragHandoff()
                savedDown = nil
                return nil
            }
            down.timestamp = event.timestamp > 0 ? event.timestamp - 1 : 0
            for replay in [down, drag] {
                replay.setIntegerValueField(.mouseEventClickState, value: 1)
                replay.setIntegerValueField(.eventSourceUserData, value: replayTag)
                replayEvent(replay)
            }
            savedDown = nil
            return nil
        }
    }
}
