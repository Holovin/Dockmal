import Foundation

@main
struct DockIconGeometryTests {
    private static var assertions = 0

    private static func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String,
                                              file: StaticString = #file, line: UInt = #line) {
        assertions += 1
        guard actual == expected else { fatalError(message, file: file, line: line) }
    }

    static func main() {
        let origin = CGPoint(x: -1500, y: 200)
        let size = CGSize(width: 64, height: 64)
        let center = CGPoint(x: -1468, y: 232)
        let expected = CGRect(origin: origin, size: size)
        expect(DockIconGeometry.frame(position: origin, size: size, containing: center), expected,
               "valid icon geometry supports negative monitor coordinates")
        expect(DockIconGeometry.frame(position: CGPoint.zero, size: CGSize(width: 512, height: 512),
                                      containing: CGPoint(x: 256, y: 256)),
               CGRect(x: 0, y: 0, width: 512, height: 512), "maximum icon size is inclusive")
        for point in [origin, CGPoint(x: -1436, y: 200), CGPoint(x: -1500, y: 264),
                      CGPoint(x: -1436, y: 264)] {
            expect(DockIconGeometry.frame(position: origin, size: size, containing: point), expected,
                   "a click exactly on an icon edge remains valid")
        }
        for point in [CGPoint(x: -1500.01, y: 232), CGPoint(x: -1435.99, y: 232),
                      CGPoint(x: -1468, y: 199.99), CGPoint(x: -1468, y: 264.01)] {
            expect(DockIconGeometry.frame(position: origin, size: size, containing: point), nil,
                   "geometry outside the current click must not highlight another icon")
        }
        expect(DockIconGeometry.frame(position: nil, size: size, containing: center), nil,
               "missing AX position produces no visual metadata")
        expect(DockIconGeometry.frame(position: origin, size: nil, containing: center), nil,
               "missing AX size produces no visual metadata")
        for invalid in [CGSize(width: 0, height: 64), CGSize(width: -1, height: 64),
                        CGSize(width: 64, height: 0), CGSize(width: 64, height: -1),
                        CGSize(width: 513, height: 64), CGSize(width: 64, height: 513),
                        CGSize(width: CGFloat.infinity, height: 64),
                        CGSize(width: 64, height: CGFloat.nan)] {
            expect(DockIconGeometry.frame(position: origin, size: invalid, containing: center), nil,
                   "invalid or unreasonable icon sizes are rejected")
        }
        for invalid in [CGPoint(x: CGFloat.nan, y: 200), CGPoint(x: -1500, y: CGFloat.infinity)] {
            expect(DockIconGeometry.frame(position: invalid, size: size, containing: center), nil,
                   "nonfinite AX positions are rejected")
            expect(DockIconGeometry.frame(position: origin, size: size, containing: invalid), nil,
                   "nonfinite click coordinates are rejected")
        }

        let appString = "file:///Applications/Test%20App.app/"
        let appURL = URL(string: appString)!
        expect(DockIconGeometry.localAppURL(appURL), appURL, "local URL values are preserved")
        expect(DockIconGeometry.localAppURL(appString), appURL, "local URL strings are parsed")
        let localhost = "file://localhost/Applications/Test.app"
        expect(DockIconGeometry.localAppURL(localhost), URL(string: localhost),
               "localhost file URLs remain local")
        let upperLocalhost = "file://LOCALHOST/Applications/Test.app"
        expect(DockIconGeometry.localAppURL(upperLocalhost), URL(string: upperLocalhost),
               "localhost hostname matching is case insensitive")
        for invalid: Any in ["https://example.com/Test.app", "file://server/share/Test.app",
                             "file:relative.app", "/Applications/Test.app", "", NSNull(),
                             "file:///Applications/Test.app?query=1", "file:///Applications/Test.app#fragment",
                             "file://user@localhost/Applications/Test.app", NSNumber(value: 42)] {
            expect(DockIconGeometry.localAppURL(invalid), nil,
                   "only unambiguous local file URLs may reach icon loading")
        }
        expect(DockIconGeometry.localAppURL(nil), nil, "missing AX URL is optional")
        testIconCanvas()
        print("Passed \(assertions) Dock icon geometry/URL assertions.")
    }

    private static func testIconCanvas() {
        // Offline screenshot fit and AX logs: the icon canvas is smaller than its item.
        let measured = CGRect(x: 634.699951171875, y: 1068, width: 68, height: 79)
        expect(DockIconGeometry.iconCanvas(in: measured, orientation: .bottom),
               CGRect(x: 636.699951171875, y: 1073, width: 64, height: 64),
               "measured bottom-Dock fixture preserves its fractional x coordinate")

        let vertical = CGRect(x: 100, y: 200, width: 79, height: 68)
        expect(DockIconGeometry.iconCanvas(in: vertical, orientation: .left),
               CGRect(x: 110, y: 202, width: 64, height: 64),
               "left Dock keeps the indicator gutter on its outer left edge")
        expect(DockIconGeometry.iconCanvas(in: vertical, orientation: .right),
               CGRect(x: 105, y: 202, width: 64, height: 64),
               "right Dock mirrors the left layout and keeps its gutter on the right")

        // Magnification changes the square canvas while leaving empirical edge padding fixed.
        for side: CGFloat in [16, 64, 96.5, 497] {
            let bottom = CGRect(x: -1500.25, y: -300.5, width: side + 4, height: side + 15)
            let vertical = CGRect(x: -1500.25, y: -300.5, width: side + 15, height: side + 4)
            expect(DockIconGeometry.iconCanvas(in: bottom, orientation: .bottom),
                   CGRect(x: -1498.25, y: -295.5, width: side, height: side),
                   "bottom padding survives magnification and negative fractional origins")
            expect(DockIconGeometry.iconCanvas(in: vertical, orientation: .left),
                   CGRect(x: -1490.25, y: -298.5, width: side, height: side),
                   "left padding survives magnification and negative fractional origins")
            expect(DockIconGeometry.iconCanvas(in: vertical, orientation: .right),
                   CGRect(x: -1495.25, y: -298.5, width: side, height: side),
                   "right padding survives magnification and negative fractional origins")
        }

        // A different indicator gutter remains allowed; it is not silently recentered.
        expect(DockIconGeometry.iconCanvas(in: CGRect(x: 0, y: 0, width: 68, height: 69), orientation: .bottom),
               CGRect(x: 2, y: 5, width: 64, height: 64), "canvas may exactly meet the outer AX edge")
        expect(DockIconGeometry.iconCanvas(in: CGRect(x: 0, y: 0, width: 68, height: 100), orientation: .bottom),
               CGRect(x: 2, y: 5, width: 64, height: 64), "extra outer space does not move the icon canvas")

        let unsupported: [(DockOrientation, CGRect)] = [
            (.bottom, CGRect(x: 0, y: 0, width: 4, height: 79)),
            (.left, CGRect(x: 0, y: 0, width: 79, height: 4)),
            (.right, CGRect(x: 0, y: 0, width: 79, height: 4)),
            (.bottom, CGRect(x: 0, y: 0, width: 68, height: 68)),
            (.left, CGRect(x: 0, y: 0, width: 68, height: 68)),
            (.right, CGRect(x: 0, y: 0, width: 68, height: 68)),
            (.bottom, CGRect(x: 0, y: 0, width: 0, height: 79)),
            (.bottom, CGRect(x: 0, y: 0, width: -68, height: 79)),
            (.left, CGRect(x: 0, y: 0, width: 79, height: -68)),
            (.bottom, CGRect(x: 0, y: 0, width: 513, height: 512)),
            (.right, CGRect(x: 0, y: 0, width: 512, height: 513)),
            (.bottom, CGRect(x: CGFloat.nan, y: 0, width: 68, height: 79)),
            (.left, CGRect(x: 0, y: CGFloat.infinity, width: 79, height: 68)),
            (.right, CGRect(x: 0, y: 0, width: CGFloat.nan, height: 68)),
            (.bottom, CGRect(x: 0, y: 0, width: 68, height: CGFloat.infinity)),
            (.bottom, CGRect(x: 1_000_000, y: 0, width: 68, height: 79))
        ]
        for (orientation, frame) in unsupported {
            expect(DockIconGeometry.iconCanvas(in: frame, orientation: orientation), nil,
                   "unsupported or invalid item geometry must omit feedback")
        }
        expect(DockOrientation(rawValue: "top"), nil, "unsupported Dock orientation is not guessed")
    }
}
