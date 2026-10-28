import Foundation

private var assertions = 0
private let origin = PointerPoint(x: 100, y: 200)
private let interval: TimeInterval = 0.5

private func expect(
    _ actual: ClickAction,
    _ expected: ClickAction,
    _ description: String,
    file: StaticString = #file,
    line: UInt = #line
) {
    assertions += 1
    guard actual == expected else {
        fatalError("\(description): expected \(expected), got \(actual)", file: file, line: line)
    }
}

private func down(
    _ gate: inout ClickGate,
    _ target: String?,
    _ time: TimeInterval,
    point: PointerPoint = origin,
    bypass: Bool = false
) -> ClickAction {
    gate.mouseDown(targetID: target, at: point, time: time, interval: interval, bypass: bypass)
}

private func down(
    _ gate: inout ClickGate,
    _ time: TimeInterval,
    point: PointerPoint = origin,
    bypass: Bool = false
) -> ClickAction {
    down(&gate, "app-a", time, point: point, bypass: bypass)
}

private func firstClick(_ gate: inout ClickGate, at time: TimeInterval = 0) {
    expect(down(&gate, time), .suppress, "first down is swallowed")
    expect(gate.mouseUp(at: origin, time: time + 0.05), .suppress, "first up is swallowed")
}

do {
    var gate = ClickGate()
    firstClick(&gate)
    expect(down(&gate, 0.2), .forwardAsSingleClick, "same icon double click activates")
    expect(gate.mouseUp(at: PointerPoint(x: 800, y: 900), time: 0.25), .forwardAsSingleClick,
           "forwarded down owns its up even outside the icon")
    expect(down(&gate, 0.3), .suppress, "third click starts a new pair")
    expect(gate.mouseUp(at: origin, time: 0.35), .suppress, "third up stays swallowed")
    expect(down(&gate, 0.4), .forwardAsSingleClick, "fourth click completes the new pair")
    expect(gate.mouseUp(at: origin, time: 0.45), .forwardAsSingleClick, "fourth up forwards")
}

do {
    var gate = ClickGate()
    firstClick(&gate)
    expect(down(&gate, "app-b", 0.2), .suppress, "another icon cannot complete a pair")
    expect(gate.mouseUp(at: origin, time: 0.25), .suppress, "other icon first up is swallowed")
    expect(down(&gate, "app-b", 0.3), .forwardAsSingleClick, "other icon now has its own pair")
}

do {
    var gate = ClickGate()
    firstClick(&gate)
    expect(down(&gate, 0.5001), .suppress, "expired interval starts a new pair")
    expect(gate.mouseUp(at: origin, time: 0.55), .suppress, "expired first up is swallowed")
    expect(down(&gate, 0.6), .forwardAsSingleClick, "new pair uses the replacement first down")
}

do {
    var gate = ClickGate()
    firstClick(&gate)
    expect(down(&gate, 0.5), .forwardAsSingleClick, "exact interval boundary is accepted")
}

do {
    var gate = ClickGate()
    expect(down(&gate, 0), .suppress, "long initial down is swallowed")
    expect(gate.mouseUp(at: origin, time: 0.4), .suppress, "release within interval can arm")
    expect(down(&gate, 0.6), .suppress, "interval is measured from down, not release")
}

do {
    var gate = ClickGate()
    expect(down(&gate, 0), .suppress, "slow hold begins captured")
    expect(gate.mouseUp(at: origin, time: 0.6), .suppress, "slow hold up is swallowed")
    expect(down(&gate, 0.7), .suppress, "slow hold never arms a pending click")
}

do {
    var gate = ClickGate()
    firstClick(&gate)
    expect(down(&gate, 0.2, point: PointerPoint(x: 106, y: 200)), .forwardAsSingleClick,
           "second click at movement boundary is accepted")
}

do {
    var gate = ClickGate()
    firstClick(&gate)
    expect(down(&gate, 0.2, point: PointerPoint(x: 106.01, y: 200)), .suppress,
           "second click beyond movement boundary starts a new pair")
}

do {
    var gate = ClickGate()
    expect(down(&gate, 0), .suppress, "moving press begins captured")
    expect(gate.mouseUp(at: PointerPoint(x: 107, y: 200), time: 0.1), .suppress,
           "captured release is swallowed even if no drag event arrived")
    expect(down(&gate, 0.2), .suppress, "moved release does not arm a pending click")
}

do {
    var gate = ClickGate()
    expect(gate.mouseUp(at: origin, time: 0), .passThrough, "unrelated up passes through")
    expect(gate.mouseDragged(to: origin, time: 0.1), .passThrough, "unrelated drag passes through")
    expect(down(&gate, nil, 0.2), .passThrough, "non-Dock down passes through")
    expect(gate.mouseUp(at: origin, time: 0.3), .passThrough, "non-Dock up passes through")
}

do {
    var gate = ClickGate()
    firstClick(&gate)
    expect(down(&gate, nil, 0.1), .passThrough, "non-Dock down cancels the pending pair")
    expect(gate.mouseUp(at: origin, time: 0.15), .passThrough, "native gesture keeps native up")
    expect(down(&gate, 0.2), .suppress, "Dock click after another native click begins again")
}

for cancellation in ["scroll", "modifier"] {
    var gate = ClickGate()
    expect(down(&gate, 0), .suppress, "\(cancellation) test starts captured")
    gate.cancelPendingGesture()
    expect(gate.mouseUp(at: origin, time: 0.1), .suppress,
           "\(cancellation) cancellation retains ownership of mouse up")
    expect(down(&gate, 0.2), .suppress,
           "\(cancellation) cancellation cannot rearm on mouse up")
}

do {
    var gate = ClickGate()
    firstClick(&gate)
    gate.cancelPendingGesture()
    expect(down(&gate, 0.2), .suppress, "cancellation clears a completed first click")
}

for cancelBeforeDrag in [false, true] {
    var gate = ClickGate()
    expect(down(&gate, 0), .suppress, "drag starts captured")
    if cancelBeforeDrag { gate.cancelPendingGesture() }
    expect(gate.mouseDragged(to: PointerPoint(x: 106, y: 200), time: 0.1), .suppress,
           "drag exactly at threshold stays captured")
    expect(gate.mouseDragged(to: PointerPoint(x: 107, y: 200), time: 0.2), .beginDrag,
           "crossing threshold hands off the captured down once")
    expect(gate.mouseDragged(to: PointerPoint(x: 110, y: 200), time: 0.3), .forwardAsSingleClick,
           "subsequent drag forwards without another replay")
    expect(gate.mouseDragged(to: origin, time: 0.35), .forwardAsSingleClick,
           "returning within threshold does not recapture a native drag")
    gate.cancelPendingGesture()
    expect(gate.mouseUp(at: origin, time: 0.4), .forwardAsSingleClick,
           "drag owns its up even after cancellation")
    expect(down(&gate, 0.45), .suppress, "drag release never arms a pending click")
}

do {
    var gate = ClickGate()
    firstClick(&gate)
    expect(down(&gate, 0.1, bypass: true), .passThrough, "bypass forwards a modified click")
    expect(gate.mouseUp(at: origin, time: 0.15), .passThrough, "bypass forwards its matching up")
    expect(down(&gate, 0.2), .suppress, "bypass cleared the earlier pending pair")
}

do {
    var gate = ClickGate()
    firstClick(&gate)
    expect(down(&gate, 0.2), .forwardAsSingleClick, "second down forwards")
    gate.cancelPendingGesture()
    expect(gate.mouseDragged(to: origin, time: 0.25), .forwardAsSingleClick,
           "forwarded second click can drag")
    expect(gate.mouseUp(at: origin, time: 0.3), .forwardAsSingleClick,
           "cancellation does not swallow the forwarded down's up")
}

do {
    var gate = ClickGate()
    firstClick(&gate)
    gate.reset()
    expect(down(&gate, 0.2), .suppress, "reset clears a pending click")
    gate.reset()
    expect(gate.mouseUp(at: origin, time: 0.3), .passThrough, "reset clears a captured press")
    expect(gate.mouseDragged(to: origin, time: 0.4), .passThrough, "reset clears drag ownership")
}

private func modeDown(
    _ gate: inout ClickGate,
    mode: DockClickMode,
    isRunning: Bool?,
    time: TimeInterval,
    applicationID: String? = "app-a"
) -> ClickAction {
    down(&gate, mode.targetID(applicationID, isRunning: isRunning), time)
}

for isRunning in [true, false] {
    var gate = ClickGate()
    expect(modeDown(&gate, mode: .allApps, isRunning: isRunning, time: 0), .suppress,
           "all-apps mode captures an app whether running or stopped")
}

for (mode, unknownStateAction) in [(DockClickMode.allApps, ClickAction.suppress), (.appsNotRunning, .passThrough)] {
    var gate = ClickGate()
    expect(modeDown(&gate, mode: mode, isRunning: nil, time: 0),
           unknownStateAction,
           "unknown running state fails open only in restricted mode")
    gate.reset()
    expect(modeDown(&gate, mode: mode, isRunning: false, time: 0, applicationID: nil), .passThrough,
           "neither mode captures an unknown application")
}

do {
    var gate = ClickGate()
    expect(modeDown(&gate, mode: .appsNotRunning, isRunning: true, time: 0), .passThrough,
           "restricted mode passes a running app down")
    expect(gate.mouseDragged(to: PointerPoint(x: 120, y: 200), time: 0.1), .passThrough,
           "running app drag remains native")
    expect(gate.mouseUp(at: origin, time: 0.2), .passThrough, "running app up remains native")
}

do {
    var gate = ClickGate()
    expect(modeDown(&gate, mode: .appsNotRunning, isRunning: false, time: 0), .suppress,
           "restricted mode captures a stopped app")
    expect(gate.mouseUp(at: origin, time: 0.05), .suppress, "stopped app first up is captured")
    expect(modeDown(&gate, mode: .appsNotRunning, isRunning: false, time: 0.2), .forwardAsSingleClick,
           "stopped app requires a double click")
    expect(gate.mouseUp(at: origin, time: 0.25), .forwardAsSingleClick, "stopped app second up forwards")
}

do {
    var gate = ClickGate()
    firstClick(&gate)
    expect(modeDown(&gate, mode: .appsNotRunning, isRunning: true, time: 0.2), .passThrough,
           "app starting between clicks makes the next down native")
    expect(gate.mouseUp(at: origin, time: 0.25), .passThrough, "newly running app up stays native")
    expect(modeDown(&gate, mode: .appsNotRunning, isRunning: false, time: 0.3), .suppress,
           "running-app click cleared the old pending pair before app stopped again")
}

do {
    var gate = ClickGate()
    var isRunning = false
    expect(modeDown(&gate, mode: .appsNotRunning, isRunning: isRunning, time: 0), .suppress,
           "stopped app down is owned by the gate")
    isRunning = true
    // The adapter only reads application state on down, never to decide its matching up.
    expect(gate.mouseUp(at: origin, time: 0.05), .suppress,
           "app starting during a captured press cannot leak its unmatched up")
    expect(modeDown(&gate, mode: .appsNotRunning, isRunning: isRunning, time: 0.2), .passThrough,
           "next down observes the new running state")
}

do {
    var gate = ClickGate()
    firstClick(&gate)
    gate.cancelPendingGesture()
    expect(modeDown(&gate, mode: .appsNotRunning, isRunning: false, time: 0.2), .suppress,
           "mode change clears a pending pair even when the same app remains eligible")
}

print("Passed \(assertions) ClickGate assertions.")
