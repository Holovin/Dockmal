import AppKit
import ApplicationServices

private final class RoutingFixture {
    var duringHit: (() -> Void)?
    var failCopyTypes = Set<CGEventType>()
    var copiedTypes: [CGEventType] = []
    var replayed: [CGEvent] = []
    var lookupCount = 0
    var feedbackJobs: [() -> Void] = []
    var feedbackEvents: [String] = []
    var frame: CGRect?

    lazy var filter = EventFilter(highlightSnapshot: { nil }, feedback: { [weak self] event in
        switch event {
        case .show: self?.feedbackEvents.append("show")
        case .hide: self?.feedbackEvents.append("hide")
        }
    },
        applicationAt: { [weak self] _, _ in
            guard let self else { return nil }
            self.lookupCount += 1
            // A one-shot hook changes configuration while the synchronous lookup is
            // in flight, after route() has captured its original configuration.
            let hook = self.duringHit
            self.duringHit = nil
            hook?()
            return DockApplication(id: "app-a", isRunning: false, frame: self.frame, appURL: nil)
        }, copyEvent: { [weak self] event in
            guard let self else { return nil }
            self.copiedTypes.append(event.type)
            return self.failCopyTypes.contains(event.type) ? nil : event.copy()
        }, scheduleFeedback: { [weak self] job in self?.feedbackJobs.append(job) }, report: { _ in })

    init() {
        filter.configure(dockPID: 100, interval: 0.5, mode: .appsNotRunning)
    }

    func route(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        filter.route(type: event.type, event: event) { [self] in replayed.append($0) }
    }
}

@main
struct EventFilterTests {
    private static var assertions = 0

    private static func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String,
                                              file: StaticString = #file, line: UInt = #line) {
        assertions += 1
        guard actual == expected else {
            FileHandle.standardError.write(Data("FAIL: \(message) (\(file):\(line))\n".utf8))
            exit(1)
        }
    }

    private static func event(_ type: CGEventType, at time: TimeInterval,
                              x: Double = 100) -> CGEvent {
        guard let event = CGEvent(source: nil) else { fatalError("Could not allocate an unposted test event") }
        event.type = type
        event.location = CGPoint(x: x, y: 200)
        event.timestamp = UInt64(time * 1_000_000_000)
        event.flags = []
        event.setIntegerValueField(.mouseEventClickState, value: 2)
        return event
    }

    private static func passedUnchanged(_ result: Unmanaged<CGEvent>?, _ original: CGEvent) -> Bool {
        result?.toOpaque() == Unmanaged.passUnretained(original).toOpaque()
            && original.getIntegerValueField(.mouseEventClickState) == 2
    }

    static func main() {
        let selected = CommandLine.arguments.dropFirst().first
        if selected == nil || selected == "stale" { testStaleLookup() }
        if selected == nil || selected == "drag" { testDragCopyFailure() }
        if selected == nil || selected == "normal" { testNormalRouting() }
        if selected == nil || selected == "transitions" { testTransitions() }
        if selected == nil || selected == "feedback" { testFeedbackTraffic() }
        print("Passed \(assertions) offline event-routing assertions.")
    }

    private static func testTransitions() {
        for stopping in [false, true] {
            let fixture = RoutingFixture()
            expect(fixture.route(event(.leftMouseDown, at: 1)) == nil, true, "capture before transition")
            if stopping {
                fixture.filter.stop()
            } else {
                fixture.filter.configure(dockPID: 101, interval: 0.5, mode: .appsNotRunning)
            }
            expect(fixture.route(event(.leftMouseDragged, at: 1.1, x: 120)) == nil, true,
                   "transition swallows drag without replaying a stale down")
            expect(fixture.route(event(.leftMouseUp, at: 1.2, x: 120)) == nil, true,
                   "transition retains ownership of the matching up")
            expect(fixture.replayed.isEmpty, true, "transition never replays input")
            let extraUp = event(.leftMouseUp, at: 1.3)
            expect(passedUnchanged(fixture.route(extraUp), extraUp), true, "ownership ends after one up")
            let down = event(.leftMouseDown, at: 1.4)
            if stopping {
                expect(passedUnchanged(fixture.route(down), down), true, "stopped filter passes future downs")
                expect(fixture.lookupCount, 1, "draining filter performs no further AX lookup")
            } else {
                expect(fixture.route(down) == nil, true, "new Dock starts with a fresh first click")
            }
        }
        let fixture = RoutingFixture()
        expect(fixture.route(event(.leftMouseDown, at: 1)) == nil, true, "capture before missing up")
        fixture.filter.stop()
        let down = event(.leftMouseDown, at: 2)
        expect(passedUnchanged(fixture.route(down), down), true, "new down recovers a lost release")
        let up = event(.leftMouseUp, at: 2.1)
        expect(passedUnchanged(fixture.route(up), up), true, "recovery preserves the new native pair")

        // Pure transition used by timeout recovery: retain suppression, disable handoff.
        var gate = ClickGate()
        let point = PointerPoint(x: 0, y: 0)
        expect(gate.mouseDown(targetID: "a", at: point, time: 1, interval: 0.5, bypass: false), .suppress,
               "timeout fixture captures down")
        gate.cancelForTransition()
        expect(gate.mouseDragged(to: PointerPoint(x: 20, y: 0), time: 1.1), .suppress,
               "timeout recovery cannot hand off a stale drag")
        expect(gate.mouseUp(at: point, time: 1.2), .suppress, "timeout recovery owns the release")
        expect(gate.mouseDown(targetID: "a", at: point, time: 1.3, interval: 0.5, bypass: false), .suppress,
               "timeout recovery never arms a second click")
    }

    private static func testFeedbackTraffic() {
        let fixture = RoutingFixture()
        for i in 0..<100 { _ = fixture.route(event(.scrollWheel, at: Double(i))) }
        expect(fixture.feedbackJobs.count, 0, "idle scrolling must not enqueue UI work")
        fixture.frame = CGRect(x: 90, y: 190, width: 68, height: 79)
        _ = fixture.route(event(.leftMouseDown, at: 101))
        expect(fixture.feedbackJobs.count, 1, "first captured click queues a show without an idle hide")
        _ = fixture.route(event(.scrollWheel, at: 101.1))
        for i in 0..<100 { _ = fixture.route(event(.scrollWheel, at: 102 + Double(i))) }
        expect(fixture.feedbackJobs.count, 2, "cancel even a pending show once, then coalesce idle hides")
        for job in fixture.feedbackJobs { job() }
        expect(fixture.feedbackEvents, ["hide"], "cancelled queued show must never flash")
        _ = fixture.route(event(.leftMouseUp, at: 203))
        _ = fixture.route(event(.leftMouseDown, at: 204))
        fixture.feedbackJobs.last?()
        expect(fixture.feedbackEvents, ["hide", "show"], "feedback can show after cancellation")
        fixture.filter.configure(dockPID: 101, interval: 0.5, mode: .appsNotRunning)
        fixture.filter.configure(dockPID: 102, interval: 0.5, mode: .allApps)
        fixture.feedbackJobs.last?()
        expect(fixture.feedbackEvents, ["hide", "show", "hide"],
               "repeated configuration must not invalidate the only queued hide")
    }

    private static func testStaleLookup() {
        do {
            let fixture = RoutingFixture()
            fixture.duringHit = { [weak fixture] in fixture?.filter.stop() }
            let down = event(.leftMouseDown, at: 1)
            expect(passedUnchanged(fixture.route(down), down), true,
                   "stop during synchronous lookup must not swallow the down")
            expect(fixture.copiedTypes.isEmpty, true, "a stale stopped down must not become a captured press")
            let up = event(.leftMouseUp, at: 1.05)
            expect(passedUnchanged(fixture.route(up), up), true, "stopped lookup retains a native down/up pair")
            expect(fixture.replayed.isEmpty, true, "stopping during lookup must not replay input")
        }

        for changePID in [false, true] {
            let fixture = RoutingFixture()
            expect(fixture.route(event(.leftMouseDown, at: 1)) == nil, true, "initial down is captured")
            expect(fixture.route(event(.leftMouseUp, at: 1.05)) == nil, true, "initial up arms a pending pair")
            fixture.duringHit = { [weak fixture] in
                fixture?.filter.configure(dockPID: changePID ? 101 : 100, interval: 0.5,
                                          mode: changePID ? .appsNotRunning : .allApps)
            }
            let down = event(.leftMouseDown, at: 1.2)
            expect(passedUnchanged(fixture.route(down), down), true,
                   "configuration changed during lookup invalidates even a pending second click")
            let up = event(.leftMouseUp, at: 1.25)
            expect(passedUnchanged(fixture.route(up), up), true, "stale lookup has no ownership of the matching up")
            expect(fixture.route(event(.leftMouseDown, at: 1.3)) == nil, true,
                   "the next eligible click starts a new pair instead of using stale pending state")
            expect(fixture.replayed.isEmpty, true, "reconfiguration never synthesizes events")
        }

        do {
            let fixture = RoutingFixture()
            fixture.duringHit = { [weak fixture] in
                fixture?.filter.configure(dockPID: 100, interval: 0.5, mode: .appsNotRunning)
            }
            expect(fixture.route(event(.leftMouseDown, at: 1)) == nil, true,
                   "an unchanged configuration refresh during lookup does not discard a valid first click")
        }
    }

    private static func testDragCopyFailure() {
        let fixture = RoutingFixture()
        fixture.failCopyTypes = [.leftMouseDragged]
        expect(fixture.route(event(.leftMouseDown, at: 1)) == nil, true, "drag candidate starts with a swallowed down")
        expect(fixture.route(event(.leftMouseDragged, at: 1.1, x: 108)) == nil, true,
               "failed drag copy must not leak a drag without its down")
        expect(fixture.replayed.isEmpty, true, "failed handoff posts neither half of the replay pair")
        expect(fixture.route(event(.leftMouseDragged, at: 1.2, x: 120)) == nil, true,
               "later drags remain swallowed after a failed handoff")
        let flags = event(.flagsChanged, at: 1.25)
        expect(fixture.route(flags)?.toOpaque() == Unmanaged.passUnretained(flags).toOpaque(), true,
               "modifier notifications still pass through")
        expect(fixture.route(event(.leftMouseUp, at: 1.3, x: 120)) == nil, true,
               "failed handoff retains ownership through mouse up even after cancellation")
        expect(fixture.copiedTypes, [.leftMouseDown, .leftMouseDragged],
               "failed handoff does not repeatedly retry drag copies")
        let unrelatedUp = event(.leftMouseUp, at: 1.35)
        expect(passedUnchanged(fixture.route(unrelatedUp), unrelatedUp), true,
               "suppression ends with the owned up")
        expect(fixture.route(event(.leftMouseDown, at: 1.4)) == nil, true,
               "failed drag never arms a pending double click")
    }

    private static func testNormalRouting() {
        do {
            let fixture = RoutingFixture()
            fixture.failCopyTypes = [.leftMouseDown]
            let down = event(.leftMouseDown, at: 1)
            expect(passedUnchanged(fixture.route(down), down), true,
                   "failure to save the initial down safely passes the original event")
            let up = event(.leftMouseUp, at: 1.05)
            expect(passedUnchanged(fixture.route(up), up), true,
                   "failed initial capture leaves its matching up native")
            expect(fixture.replayed.isEmpty, true, "failed initial capture never replays input")
        }
        do {
            let fixture = RoutingFixture()
            expect(fixture.route(event(.leftMouseDown, at: 1)) == nil, true, "successful drag starts captured")
            expect(fixture.route(event(.leftMouseDragged, at: 1.1, x: 108)) == nil, true,
                   "successful handoff consumes the original crossing drag")
            expect(fixture.replayed.map(\.type), [.leftMouseDown, .leftMouseDragged],
                   "successful handoff still replays down then drag through the injected sink")
            expect(fixture.replayed.map { $0.getIntegerValueField(.mouseEventClickState) }, [1, 1],
                   "both replay events are normalized to a single click")
            let up = event(.leftMouseUp, at: 1.2, x: 108)
            expect(fixture.route(up) != nil, true, "successful handoff forwards its matching up")
            expect(up.getIntegerValueField(.mouseEventClickState), 1, "forwarded drag up is normalized")
        }
    }
}
