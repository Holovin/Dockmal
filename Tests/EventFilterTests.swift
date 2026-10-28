import AppKit
import ApplicationServices

private final class RoutingFixture {
    var duringHit: (() -> Void)?
    var failCopyTypes = Set<CGEventType>()
    var copiedTypes: [CGEventType] = []
    var replayed: [CGEvent] = []

    lazy var filter = EventFilter(highlightSnapshot: { nil }, feedback: { _ in },
        applicationAt: { [weak self] _, _ in
            guard let self else { return nil }
            // A one-shot hook changes configuration while the synchronous lookup is
            // in flight, after route() has captured its original configuration.
            let hook = self.duringHit
            self.duringHit = nil
            hook?()
            return DockApplication(id: "app-a", isRunning: false, frame: nil, appURL: nil)
        }, copyEvent: { [weak self] event in
            guard let self else { return nil }
            self.copiedTypes.append(event.type)
            return self.failCopyTypes.contains(event.type) ? nil : event.copy()
        }, report: { _ in })

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
        print("Passed \(assertions) offline event-routing assertions.")
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
