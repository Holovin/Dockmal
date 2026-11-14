import Foundation

@main
struct OverlayHitPolicyTests {
    private static var assertions = 0
    private static let point = CGPoint(x: 150, y: 150)
    private static let overlayFrame = CGRect(x: 100, y: 100, width: 100, height: 100)
    private static let dockFrame = CGRect(x: 50, y: 80, width: 400, height: 150)

    private static func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String,
                                              file: StaticString = #file, line: UInt = #line) {
        assertions += 1
        guard actual == expected else { fatalError(message, file: file, line: line) }
    }

    private static func window(_ number: Int? = 10, owner: Int32? = 100,
                               frame: CGRect? = overlayFrame, alpha: Double? = 1,
                               onscreen: Bool? = true) -> OverlayWindowInfo {
        OverlayWindowInfo(number: number, ownerPID: owner, frame: frame,
                          alpha: alpha, isOnscreen: onscreen)
    }

    private static func allows(_ windows: [OverlayWindowInfo], at point: CGPoint = point,
                               snapshotFrame: CGRect = overlayFrame,
                               ownPID: Int32 = 100, dockPID: Int32 = 200) -> Bool {
        OverlayHitPolicy.allowsDockFallback(at: point, overlayWindowNumber: 10,
            overlayFrame: snapshotFrame, ownPID: ownPID, dockPID: dockPID, windows: windows)
    }

    static func main() {
        let overlay = window()
        let dock = window(20, owner: 200, frame: dockFrame)
        let foreign = window(30, owner: 300)
        let ownMenu = window(40)
        let outside = window(50, owner: 300, frame: CGRect(x: 500, y: 0, width: 50, height: 50))
        let cases: [([OverlayWindowInfo], Bool, String)] = [
            ([overlay, dock], true, "known overlay directly over Dock allows scoped lookup"),
            ([overlay, dock, foreign], true, "windows behind Dock do not affect the hit"),
            ([outside, overlay, dock], true, "valid windows outside the point do not obscure Dock"),
            ([foreign, overlay, dock], false, "foreign window above overlay prevents fallback"),
            ([overlay, foreign, dock], false, "foreign window under overlay must not be bypassed"),
            ([overlay, ownMenu, dock], false, "our own menu is not the decorative overlay"),
            ([ownMenu, overlay, dock], false, "our own frontmost menu must remain authoritative"),
            ([dock], false, "missing overlay cannot authorize scoped lookup"),
            ([overlay], false, "overlay without a Dock window is insufficient"),
            ([], false, "empty window list fails closed"),
            ([dock, overlay], false, "overlay must actually precede Dock at the point"),
            ([window(10, owner: 300), dock], false, "overlay number with foreign owner is not ours"),
            ([window(11), dock], false, "an unrelated own window cannot substitute for overlay"),
            ([window(frame: CGRect(x: 500, y: 0, width: 50, height: 50)), dock], false,
             "actual overlay bounds must contain the point too"),
            ([overlay, overlay, dock], false, "duplicate overlay metadata is ambiguous"),
            ([window(30, owner: 300, alpha: 0), overlay, dock], true,
             "explicitly transparent foreign window can be skipped"),
            ([window(nil, owner: nil, frame: nil, alpha: nil, onscreen: false), overlay, dock], true,
             "explicitly offscreen record can be skipped without other metadata"),
            ([window(nil, owner: nil, frame: nil, alpha: 0, onscreen: nil), overlay, dock], true,
             "explicit zero alpha proves invisibility despite missing other fields"),
            ([window(alpha: 0), dock], false, "invisible overlay does not establish presence"),
            ([window(onscreen: false), dock], false, "offscreen overlay does not establish presence"),
            ([window(nil, owner: 100), dock], false, "missing window number fails closed"),
            ([window(owner: nil), dock], false, "missing owner fails closed"),
            ([window(frame: nil), dock], false, "missing bounds fail closed"),
            ([window(alpha: nil), dock], false, "unknown alpha is not assumed invisible"),
            ([window(onscreen: nil), dock], false, "unknown visibility fails closed"),
            ([window(alpha: .nan), dock], false, "nonfinite alpha fails closed"),
            ([window(alpha: 1.1), dock], false, "out-of-range alpha fails closed"),
            ([window(frame: CGRect(x: 100, y: 100, width: 0, height: 10)), dock], false,
             "empty bounds fail closed"),
            ([window(frame: CGRect(x: CGFloat.infinity, y: 100, width: 100, height: 100)), dock], false,
             "nonfinite bounds fail closed"),
            ([overlay, window(20, owner: nil, frame: dockFrame)], false,
             "missing candidate owner never implies Dock")
        ]
        for (windows, expected, message) in cases { expect(allows(windows), expected, message) }
        expect(allows([overlay, dock], at: CGPoint(x: 90, y: 150)), false,
               "point outside published overlay bounds cannot trigger fallback")
        expect(allows([overlay, dock], at: CGPoint(x: CGFloat.nan, y: 150)), false,
               "nonfinite pointer coordinates fail closed")
        expect(allows([overlay, dock], ownPID: 0), false, "invalid own PID fails closed")
        expect(allows([overlay, dock], dockPID: 0), false, "invalid Dock PID fails closed")
        expect(allows([overlay, dock], dockPID: 100), false, "Dock and app identities must differ")

        expect(OverlayHitPolicy.mayHitDock(at: point, dockPID: 200, windows: [dock]), true,
               "Dock point reaches AX")
        expect(OverlayHitPolicy.mayHitDock(at: CGPoint(x: 700, y: 700), dockPID: 200,
                                          windows: [foreign, dock]), false,
               "ordinary application point outside Dock avoids AX")
        expect(OverlayHitPolicy.mayHitDock(at: point, dockPID: 200, windows: [foreign, dock]), true,
               "prefilter cannot replace the authoritative AX occlusion check")
        expect(OverlayHitPolicy.mayHitDock(at: point, dockPID: 200, windows: nil), true,
               "unavailable WindowServer metadata falls back to AX")
        expect(OverlayHitPolicy.mayHitDock(at: point, dockPID: 200, windows: []), true,
               "empty snapshot is not proof that Dock cannot be hit")
        expect(OverlayHitPolicy.mayHitDock(at: point, dockPID: 200,
                                          windows: [window(owner: 200, frame: nil)]), true,
               "unknown Dock bounds cannot reject a point")
        expect(OverlayHitPolicy.mayHitDock(at: point, dockPID: 200,
                                          windows: [window(owner: nil)]), true,
               "unknown owner cannot exclude Dock")
        expect(OverlayHitPolicy.mayHitDock(at: CGPoint(x: 450, y: 230), dockPID: 200,
                                          windows: [dock]), true, "exact Dock edges are included")
        let moved = window(21, owner: 200, frame: CGRect(x: -1000, y: -100, width: 100, height: 700))
        expect(OverlayHitPolicy.mayHitDock(at: CGPoint(x: -950, y: 0), dockPID: 200,
                                          windows: [dock, moved]), true,
               "multiple Dock windows and negative screen coordinates are supported")
        expect(OverlayHitPolicy.mayHitDock(at: point, dockPID: 200, windows: [moved]), false,
               "fresh bounds follow Dock relocation without stale cached regions")

        print("Passed \(assertions) overlay policy assertions.")
    }

}
