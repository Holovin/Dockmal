import Foundation

enum DockClickMode {
    case allApps
    case appsNotRunning

    func targetID(_ applicationID: String?, isRunning: Bool?) -> String? {
        guard self == .allApps || isRunning == false else { return nil }
        return applicationID
    }
}

struct PointerPoint: Equatable {
    let x: Double
    let y: Double

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    fileprivate func squaredDistance(to other: PointerPoint) -> Double {
        let dx = x - other.x
        let dy = y - other.y
        return dx * dx + dy * dy
    }
}

enum ClickAction: Equatable {
    case passThrough
    case suppress
    case forwardAsSingleClick
    case beginDrag
}

/// Decides which events belong to a captured Dock click. The adapter performs
/// hit testing only on mouse down and handles replay when a drag starts.
struct ClickGate {
    private struct FirstClick {
        let targetID: String
        let point: PointerPoint
        let downTime: TimeInterval
    }

    private struct CapturedPress {
        let click: FirstClick
        let interval: TimeInterval
        var cancelled = false
    }

    private enum Press {
        case captured(CapturedPress)
        case forwarding
        case suppressingUntilMouseUp
    }

    private let movementToleranceSquared: Double
    private var pending: FirstClick?
    private var press: Press?

    var ownsSuppressedPress: Bool {
        switch press {
        case .captured, .suppressingUntilMouseUp: return true
        case .forwarding, nil: return false
        }
    }

    /// End recognition without leaking the remainder of an intercepted press.
    /// Unlike ordinary cancellation, a process/tap transition must not replay a drag.
    mutating func cancelForTransition() {
        pending = nil
        if ownsSuppressedPress { press = .suppressingUntilMouseUp }
    }

    init(movementTolerance: Double = 6) {
        let tolerance = max(0, movementTolerance)
        movementToleranceSquared = tolerance * tolerance
    }

    mutating func mouseDown(
        targetID: String?,
        at point: PointerPoint,
        time: TimeInterval,
        interval: TimeInterval,
        bypass: Bool
    ) -> ClickAction {
        let firstClick = pending
        pending = nil
        press = nil

        guard !bypass, let targetID else {
            return .passThrough
        }

        if let firstClick,
           firstClick.targetID == targetID,
           time >= firstClick.downTime,
           time - firstClick.downTime <= interval,
           firstClick.point.squaredDistance(to: point) <= movementToleranceSquared {
            press = .forwarding
            return .forwardAsSingleClick
        }

        press = .captured(CapturedPress(
            click: FirstClick(targetID: targetID, point: point, downTime: time),
            interval: interval
        ))
        return .suppress
    }

    mutating func mouseUp(at point: PointerPoint, time: TimeInterval) -> ClickAction {
        let completedPress = press
        press = nil

        switch completedPress {
        case .captured(let captured):
            pending = nil
            if !captured.cancelled,
               time >= captured.click.downTime,
               time - captured.click.downTime <= captured.interval,
               captured.click.point.squaredDistance(to: point) <= movementToleranceSquared {
                pending = captured.click
            }
            return .suppress
        case .forwarding:
            return .forwardAsSingleClick
        case .suppressingUntilMouseUp:
            return .suppress
        case nil:
            return .passThrough
        }
    }

    mutating func mouseDragged(to point: PointerPoint, time: TimeInterval) -> ClickAction {
        switch press {
        case .captured(let captured):
            guard captured.click.point.squaredDistance(to: point) > movementToleranceSquared else {
                return .suppress
            }
            pending = nil
            press = .forwarding
            return .beginDrag
        case .forwarding:
            return .forwardAsSingleClick
        case .suppressingUntilMouseUp:
            return .suppress
        case nil:
            return .passThrough
        }
    }

    /// A drag handoff was selected, but no down was replayed. Keep swallowing
    /// this press through its up so native consumers never receive an orphan drag.
    mutating func abortDragHandoff() {
        pending = nil
        press = .suppressingUntilMouseUp
    }

    /// Cancel recognition while retaining ownership of a swallowed mouse down.
    /// A later mouse up must still be swallowed and must not arm another click.
    mutating func cancelPendingGesture() {
        pending = nil
        if case .captured(var captured) = press {
            captured.cancelled = true
            press = .captured(captured)
        }
    }

    /// Forget all state only when there is no intercepted press to finish.
    mutating func reset() {
        pending = nil
        press = nil
    }
}
