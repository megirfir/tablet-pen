import Foundation

public enum PointingMode: String, Codable, Sendable, CaseIterable { case relative, absolute }

/// How the tablet surface is fitted to a screen whose aspect ratio differs.
public enum AspectFit: String, Codable, Sendable, CaseIterable {
    /// Whole screen reachable, shapes undistorted; part of the tablet is unused.
    case letterbox
    /// Whole tablet used, shapes undistorted; part of the screen is unreachable.
    case crop
    /// Whole tablet maps to the whole screen; shapes are distorted.
    case stretch
}

public struct Settings: Codable, Equatable, Sendable {
    // Pointing
    public var fingerMode: PointingMode = .relative
    public var penMode: PointingMode = .absolute
    public var sensitivity: Double = 1.0        // 0.2 ... 3
    public var acceleration: Double = 1.0       // 0 (off) ... 2
    public var aspectFit: AspectFit = .letterbox
    /// CGDirectDisplayID of the target screen for absolute mapping; 0 = main display.
    public var targetDisplay: UInt32 = 0

    // Gestures
    public var tapToClick = true
    public var tapAndDrag = true
    public var threeFingerDrag = true
    public var naturalScroll = true
    public var scrollSpeed: Double = 1.0
    public var momentumScroll = true
    public var pinchZoom = true

    // Pen (defaults from the M0 measurements on the Tab Pen Plus — see NOTES.md)
    public var pressure = PressureCurve()
    public var tilt = TiltCurve()

    // Debug
    public var showHUD = false

    public init() {}

    public init(from decoder: Decoder) throws {
        // Tolerant decoding: missing keys keep their defaults, so adding settings never resets old ones.
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ k: CodingKeys, _ v: inout T) { if let x = try? c.decode(T.self, forKey: k) { v = x } }
        get(.fingerMode, &fingerMode); get(.penMode, &penMode); get(.sensitivity, &sensitivity)
        get(.acceleration, &acceleration); get(.aspectFit, &aspectFit); get(.targetDisplay, &targetDisplay)
        get(.tapToClick, &tapToClick); get(.tapAndDrag, &tapAndDrag); get(.threeFingerDrag, &threeFingerDrag)
        get(.naturalScroll, &naturalScroll); get(.scrollSpeed, &scrollSpeed); get(.momentumScroll, &momentumScroll)
        get(.pinchZoom, &pinchZoom); get(.pressure, &pressure); get(.tilt, &tilt); get(.showHUD, &showHUD)
    }
}

/// Physical size of the tablet's capture surface.
public struct Surface: Equatable, Sendable {
    public var widthIn: Double
    public var heightIn: Double
    public init(widthIn: Double, heightIn: Double) { self.widthIn = widthIn; self.heightIn = heightIn }
    public init(widthPx: Int, heightPx: Int, dpi: Int) {
        let d = Double(max(dpi, 1))
        self.init(widthIn: Double(widthPx) / d, heightIn: Double(heightPx) / d)
    }
    public var aspect: Double { heightIn > 0 ? widthIn / heightIn : 1.6 }
    /// Idea Tab Pro 12.7" in landscape.
    public static let `default` = Surface(widthIn: 10.78, heightIn: 6.74)
}
