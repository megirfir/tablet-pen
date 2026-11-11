import Foundation

public struct Rect: Equatable, Sendable {
    public var x, y, width, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public func contains(_ px: Double, _ py: Double) -> Bool { px >= x && px < maxX && py >= y && py < maxY }
    public func clamp(_ px: Double, _ py: Double) -> (x: Double, y: Double) {
        (min(max(px, x), maxX - 1), min(max(py, y), maxY - 1))
    }
}

/// Absolute mapping from the normalized tablet surface to a target rectangle in global display
/// coordinates (points, origin top-left of the main display — the CGEvent coordinate space, so
/// Retina scaling needs no special handling).
public struct AbsoluteMapper: Equatable, Sendable {
    public var tabletAspect: Double
    public var target: Rect
    public var fit: AspectFit

    public init(tabletAspect: Double, target: Rect, fit: AspectFit) {
        self.tabletAspect = tabletAspect; self.target = target; self.fit = fit
    }

    /// The part of the tablet (normalized) that is in use.
    public var activeTabletArea: Rect {
        let ta = tabletAspect, sa = target.width / target.height
        guard fit == .letterbox, ta > 0, sa > 0 else { return Rect(x: 0, y: 0, width: 1, height: 1) }
        if ta > sa {            // tablet is wider than the screen: unused bands left and right
            let w = sa / ta
            return Rect(x: (1 - w) / 2, y: 0, width: w, height: 1)
        } else {                // tablet is taller: unused bands top and bottom
            let h = ta / sa
            return Rect(x: 0, y: (1 - h) / 2, width: 1, height: h)
        }
    }

    /// The part of the target rectangle that can be reached.
    public var reachableTarget: Rect {
        let ta = tabletAspect, sa = target.width / target.height
        guard fit == .crop, ta > 0, sa > 0 else { return target }
        if ta > sa {            // tablet wider: full width, reduced height
            let h = target.width / ta
            return Rect(x: target.x, y: target.y + (target.height - h) / 2, width: target.width, height: h)
        } else {
            let w = target.height * ta
            return Rect(x: target.x + (target.width - w) / 2, y: target.y, width: w, height: target.height)
        }
    }

    public func map(nx: Double, ny: Double) -> (x: Double, y: Double) {
        let a = activeTabletArea, r = reachableTarget
        let u = min(max((nx - a.x) / a.width, 0), 1)
        let v = min(max((ny - a.y) / a.height, 0), 1)
        // Keep the result inside the rectangle (the last addressable point is max - 1).
        return (r.x + u * (r.width - 1), r.y + v * (r.height - 1))
    }
}

/// Keeps a relatively-moved cursor on the desktop when there are several displays: a move may
/// cross into any display; if it would leave all of them it is clamped to the display it was on.
public func clampToDisplays(x: Double, y: Double, from: (x: Double, y: Double), displays: [Rect]) -> (x: Double, y: Double) {
    if displays.contains(where: { $0.contains(x, y) }) { return (x, y) }
    let home = displays.first(where: { $0.contains(from.x, from.y) }) ?? displays.first
    guard let h = home else { return (x, y) }
    return h.clamp(x, y)
}
