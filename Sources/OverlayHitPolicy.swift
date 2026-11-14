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
    /// A fresh WindowServer snapshot rejects points outside Dock windows before AX
    /// contacts the application under the pointer. Missing metadata fails open to AX.
    /// This is only a spatial prefilter; AX still decides ownership and item identity.
    static func mayHitDock(at point: CGPoint, dockPID: Int32,
                           windows: [OverlayWindowInfo]?) -> Bool {
        guard point.x.isFinite, point.y.isFinite, dockPID > 0,
              let windows, !windows.isEmpty else { return true }
        for window in windows {
            if window.isOnscreen == false { continue }
            guard let owner = window.ownerPID, owner > 0 else { return true }
            guard owner == dockPID else { continue }
            guard let frame = window.frame, validFrame(frame) else { return true }
            if point.x >= frame.minX && point.x <= frame.maxX &&
                point.y >= frame.minY && point.y <= frame.maxY { return true }
        }
        return false
    }

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
