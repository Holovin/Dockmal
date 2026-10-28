import Foundation
import CoreGraphics

/// A deliberately incomplete record is retained so missing metadata cannot be
/// mistaken for a window that is safe to ignore.
struct OverlayWindowInfo {
    let number: Int?
    let ownerPID: Int32?
    let frame: CGRect?
    let alpha: Double?
    let isOnscreen: Bool?
}

enum OverlayHitPolicy {
    static func allowsDockFallback(
        at point: CGPoint,
        overlayWindowNumber: Int,
        overlayFrame: CGRect,
        ownPID: Int32,
        dockPID: Int32,
        windows: [OverlayWindowInfo]
    ) -> Bool {
        guard point.x.isFinite, point.y.isFinite,
              overlayWindowNumber > 0, ownPID > 0, dockPID > 0, ownPID != dockPID,
              validFrame(overlayFrame), overlayFrame.contains(point) else { return false }

        var sawOverlay = false
        for window in windows {
            // Only explicit invisibility is sufficient to skip unknown fields.
            if window.isOnscreen == false || window.alpha == 0 { continue }
            guard window.isOnscreen == true,
                  let alpha = window.alpha, alpha.isFinite, alpha > 0, alpha <= 1,
                  let frame = window.frame, validFrame(frame),
                  let number = window.number, number > 0,
                  let owner = window.ownerPID, owner > 0 else { return false }
            guard frame.contains(point) else { continue }
            if number == overlayWindowNumber {
                guard owner == ownPID, !sawOverlay else { return false }
                sawOverlay = true
                continue
            }
            // This includes our own menus and alerts: never skip an entire PID.
            return sawOverlay && owner == dockPID
        }
        return false
    }

    private static func validFrame(_ frame: CGRect) -> Bool {
        [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height]
            .allSatisfy { $0.isFinite }
            && frame.size.width > 0 && frame.size.height > 0
    }
}
