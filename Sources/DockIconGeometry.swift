import Foundation
import CoreGraphics

enum DockOrientation: String {
    case bottom
    case left
    case right
}

enum DockIconGeometry {
    /// AX/CG global coordinates. Require the observed icon to still cover this click;
    /// stale geometry during Dock magnification should disable feedback, not filtering.
    static func frame(position: CGPoint?, size: CGSize?, containing click: CGPoint) -> CGRect? {
        guard let position, let size,
              [position.x, position.y, size.width, size.height, click.x, click.y].allSatisfy({ $0.isFinite }),
              size.width > 0, size.height > 0, size.width <= 512, size.height <= 512 else { return nil }
        let frame = CGRect(origin: position, size: size)
        // Include exact edges, without expanding the AX rectangle into a nearby icon.
        guard click.x >= position.x, click.x <= position.x + size.width,
              click.y >= position.y, click.y <= position.y + size.height else { return nil }
        return frame
    }

    /// Empirically calibrated Dock layout, not a public API guarantee: the measured
    /// 68 x 79 AX item contains a 64 x 64 icon canvas at (+2, +5) for a bottom Dock.
    /// Keep two points on each along-Dock edge and five on the inward edge; the
    /// remaining outer space is the running-indicator gutter. Unsupported geometry
    /// omits feedback only. Preserve fractional coordinates for the renderer.
    static func iconCanvas(in itemFrame: CGRect, orientation: DockOrientation) -> CGRect? {
        guard [itemFrame.origin.x, itemFrame.origin.y, itemFrame.size.width, itemFrame.size.height]
                .allSatisfy({ $0.isFinite }),
              abs(itemFrame.origin.x) < 1_000_000, abs(itemFrame.origin.y) < 1_000_000,
              itemFrame.size.width > 0, itemFrame.size.height > 0,
              itemFrame.size.width <= 512, itemFrame.size.height <= 512 else { return nil }

        let side = (orientation == .bottom ? itemFrame.size.width : itemFrame.size.height) - 4
        guard side > 0 else { return nil }
        let origin: CGPoint
        switch orientation {
        case .bottom:
            origin = CGPoint(x: itemFrame.minX + 2, y: itemFrame.minY + 5)
        case .left:
            origin = CGPoint(x: itemFrame.maxX - 5 - side, y: itemFrame.minY + 2)
        case .right:
            origin = CGPoint(x: itemFrame.minX + 5, y: itemFrame.minY + 2)
        }
        let canvas = CGRect(origin: origin, size: CGSize(width: side, height: side))
        guard [canvas.minX, canvas.minY, canvas.maxX, canvas.maxY].allSatisfy({ $0.isFinite }),
              canvas.minX >= itemFrame.minX, canvas.minY >= itemFrame.minY,
              canvas.maxX <= itemFrame.maxX, canvas.maxY <= itemFrame.maxY else { return nil }
        return canvas
    }

    /// Parse only a local file URL supplied by AX. No path probing or file reads.
    static func localAppURL(_ value: Any?) -> URL? {
        let candidate: URL?
        if let url = value as? URL {
            candidate = url
        } else if let string = value as? String {
            candidate = URL(string: string)
        } else {
            candidate = nil
        }
        guard let url = candidate, url.isFileURL, url.path.hasPrefix("/"),
              url.host == nil || url.host == "" || url.host?.lowercased() == "localhost",
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil else { return nil }
        return url
    }
}
