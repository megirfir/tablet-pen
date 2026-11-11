import Foundation

/// Maps raw pen pressure (0...1) to output pressure (0...1):
/// `out = ((p - low) / (high - low)) ^ gamma`, clamped.
public struct PressureCurve: Codable, Equatable, Sendable {
    /// Raw pressure at or below this is 0. Measured lightest strokes: 0.02–0.09.
    public var low: Double = 0.02
    /// Raw pressure at or above this is 1. Measured hard strokes: 0.85–0.96.
    public var high: Double = 0.90
    /// > 1 makes light pressure softer. Default puts normal writing pressure (~0.6 raw) at ~0.5.
    public var gamma: Double = 1.66

    public init() {}
    public init(low: Double, high: Double, gamma: Double) { self.low = low; self.high = high; self.gamma = gamma }

    public func apply(_ p: Double) -> Double {
        guard high > low else { return p >= high ? 1 : 0 }
        let t = min(max((p - low) / (high - low), 0), 1)
        return pow(t, gamma)
    }

    /// Builds a curve from the three calibration strokes (typical raw pressure of each).
    /// Light maps near 0, hard to 1 and medium to 0.5.
    public static func calibrated(light: Double, medium: Double, hard: Double) -> PressureCurve {
        let lo = max(0, min(light * 0.5, 0.5))
        let hi = min(1, max(hard, lo + 0.1))
        let m = min(max((medium - lo) / (hi - lo), 0.05), 0.95)
        let g = min(max(log(0.5) / log(m), 0.3), 4)
        return PressureCurve(low: lo, high: hi, gamma: g)
    }
}

/// Tilt dead zone and response curve. Works on the tilt magnitude (angle from vertical) and
/// keeps the lean direction.
public struct TiltCurve: Codable, Equatable, Sendable {
    /// Below this angle from vertical the pen counts as upright. The Tab Pen Plus reads ~45° in a
    /// normal writing grip, so the default sits just above that.
    public var deadZoneDeg: Double = 50
    /// Angle that maps to full output tilt. Measured maximum ≈ 70°.
    public var maxDeg: Double = 70
    /// > 1 = gentler onset just past the dead zone.
    public var gamma: Double = 1.5
    /// Largest tilt reported to apps, in degrees.
    public var outputMaxDeg: Double = 60

    public init() {}
    public init(deadZoneDeg: Double, maxDeg: Double, gamma: Double, outputMaxDeg: Double) {
        self.deadZoneDeg = deadZoneDeg; self.maxDeg = maxDeg; self.gamma = gamma; self.outputMaxDeg = outputMaxDeg
    }

    /// Input and output are (tiltX, tiltY) in degrees.
    public func apply(tiltX: Double, tiltY: Double) -> (x: Double, y: Double) {
        let mag = hypot(tiltX, tiltY)
        guard mag > deadZoneDeg, mag > 0, maxDeg > deadZoneDeg else { return (0, 0) }
        let t = min((mag - deadZoneDeg) / (maxDeg - deadZoneDeg), 1)
        let out = pow(t, gamma) * outputMaxDeg
        return (tiltX / mag * out, tiltY / mag * out)
    }
}

/// Pointer speed for relative movement, in screen points per inch of finger/pen travel.
/// Slow movement stays near the base speed for precision; fast movement is amplified.
public func pointerGain(speedInPerSec v: Double, sensitivity: Double, acceleration: Double) -> Double {
    let base = 300.0 * sensitivity
    let boost = min(pow(max(v, 0) / 5.0, 1.3), 6)
    return base * (1 + acceleration * boost)
}
