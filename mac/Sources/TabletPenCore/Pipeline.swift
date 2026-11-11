import Foundation

/// Pen as a pointer: hover moves the cursor, contact is a left press/drag, the Bluetooth side
/// button is a right-click.
public final class PenTracker {
    public var settings: Settings
    public var surface: Surface

    let clickSlop = 0.02            // inches the tip may wander before a press becomes a drag
    let doubleClickWindow = 0.35
    let bounceGap = 0.04           // tip re-touching this soon after lifting is bounce, not a second click
    let doubleClickDistance = 0.12

    private var last: (x: Double, y: Double)?
    private var lastTime = 0.0
    private var speed = 0.0
    private var isDown = false
    private var downAt: (x: Double, y: Double) = (0, 0)
    private var dragging = false
    private var lastClick: (t: Double, x: Double, y: Double, count: Int) = (-10, 0, 0, 0)
    private var lastUpTime = -10.0
    public private(set) var inProximity = false

    public init(settings: Settings = Settings(), surface: Surface = .default) {
        self.settings = settings; self.surface = surface
    }

    private func penState(_ s: Sample, contact: Bool, proximity: Bool) -> OutputEvent {
        let tilt = settings.tilt.apply(tiltX: Double(s.tiltX), tiltY: Double(s.tiltY))
        return .pen(pressure: contact ? settings.pressure.apply(s.np) : 0,
                    tiltX: tilt.x, tiltY: tilt.y, inContact: contact, inProximity: proximity)
    }

    private func move(_ s: Sample, _ x: Double, _ y: Double, _ t: Double) -> [OutputEvent] {
        defer { last = (x, y) }
        if settings.penMode == .absolute { return [.moveTo(nx: s.nx, ny: s.ny)] }
        guard let l = last else { lastTime = t; return [] }
        let dx = x - l.x, dy = y - l.y
        if dx == 0, dy == 0 { return [] }
        let dt = t - lastTime
        if dt > 0 {
            let inst = hypot(dx, dy) / dt
            speed = dt > 0.1 ? inst : speed * 0.6 + inst * 0.4
            lastTime = t
        }
        let g = pointerGain(speedInPerSec: speed, sensitivity: settings.sensitivity, acceleration: settings.acceleration)
        return [.moveBy(dx: dx * g, dy: dy * g)]
    }

    public func handle(_ s: Sample, time t: Double) -> [OutputEvent] {
        let x = s.nx * surface.widthIn, y = s.ny * surface.heightIn
        var out: [OutputEvent] = []
        switch s.action {
        case .hoverEnter:
            inProximity = true; last = nil
            out += move(s, x, y, t)
            out.append(penState(s, contact: false, proximity: true))
        case .hoverMove:
            inProximity = true
            out.append(penState(s, contact: false, proximity: true))
            out += move(s, x, y, t)
        case .hoverExit:
            inProximity = false; last = nil
            out.append(penState(s, contact: false, proximity: false))
        case .down:
            inProximity = true
            if !isDown {
                out += move(s, x, y, t)
                let near = hypot(x - lastClick.x, y - lastClick.y) < doubleClickDistance
                let count: Int
                if near, t - lastUpTime < bounceGap { count = max(lastClick.count, 1) }      // bounce: same click
                else { count = (t - lastClick.t < doubleClickWindow && near) ? lastClick.count + 1 : 1 }
                lastClick = (t, x, y, count)
                isDown = true; dragging = false; downAt = (x, y)
                out.append(penState(s, contact: true, proximity: true))
                out.append(.button(.left, down: true, clicks: count))
            }
        case .move:
            guard isDown else { break }
            out.append(penState(s, contact: true, proximity: true))
            if !dragging {
                guard hypot(x - downAt.x, y - downAt.y) >= clickSlop else { break }
                dragging = true
                if settings.penMode == .relative { last = (x, y); break }
            }
            out += move(s, x, y, t)
        case .up, .cancel:
            if isDown {
                isDown = false
                lastUpTime = t
                out.append(penState(s, contact: false, proximity: true))
                out.append(.button(.left, down: false, clicks: lastClick.count))
            }
            last = (x, y)
        }
        return out
    }

    /// kind: 1 click, 2 double click, 3 long press (Tab Pen Plus Bluetooth button).
    public func button(kind: UInt8) -> [OutputEvent] {
        guard kind == 1 else { return [] }
        return [.button(.right, down: true, clicks: 1), .button(.right, down: false, clicks: 1)]
    }

    public func cancelAll() -> [OutputEvent] {
        defer { isDown = false; last = nil; inProximity = false }
        return isDown ? [.button(.left, down: false, clicks: 1)] : []
    }
}

/// Routes decoded messages to the finger and pen recognizers. One instance per connection.
public final class InputPipeline {
    public var settings: Settings {
        didSet { gestures.settings = settings; pen.settings = settings }
    }
    public private(set) var surface: Surface
    public let gestures: GestureRecognizer
    public let pen: PenTracker

    /// Fingers are ignored while the pen is near the screen and for this long afterwards.
    let palmGuard = 0.25
    private var penSeenAt = -10.0

    public init(settings: Settings = Settings(), surface: Surface = .default) {
        self.settings = settings; self.surface = surface
        gestures = GestureRecognizer(settings: settings, surface: surface)
        pen = PenTracker(settings: settings, surface: surface)
    }

    public func setSurface(_ s: Surface) {
        surface = s; gestures.surface = s; pen.surface = s
    }

    public func handle(_ m: Message) -> [OutputEvent] {
        switch m {
        case let .hello(_, _, width, height, _, dpi, _):
            if width > 0, height > 0, dpi > 0 {
                setSurface(Surface(widthPx: Int(width), heightPx: Int(height), dpi: Int(dpi)))
            }
            return []
        case let .input(base, samples):
            var out: [OutputEvent] = []
            for s in samples {
                let t = Double(base + UInt64(s.dtMicros)) / 1e6
                switch s.tool {
                case .pen, .eraser:
                    if !gestures.isIdle, t - penSeenAt > palmGuard { out += gestures.cancelAll() }
                    penSeenAt = t
                    out += pen.handle(s, time: t)
                case .finger, .mouse:
                    if pen.inProximity || t - penSeenAt < palmGuard { continue }
                    out += gestures.handle(s, time: t)
                }
            }
            return out
        case let .penButton(kind):
            return pen.button(kind: kind)
        default:
            return []
        }
    }

    public func tick(now: Double) -> [OutputEvent] { gestures.tick(now: now) }

    public func reset() -> [OutputEvent] { gestures.cancelAll() + pen.cancelAll() }
}

/// Estimates the tablet-clock → Mac-clock offset from PING/PONG so per-sample latency can be measured.
public struct ClockSync: Sendable {
    public private(set) var offsetMicros: Int64?      // tabletClock - macClock
    public private(set) var rttMicros: Int64?
    private var bestRtt = Int64.max
    private var samples = 0

    public init() {}

    /// macSent/macReceived are Mac clock, tabletTime is the tablet clock when it answered.
    public mutating func update(macSent: UInt64, macReceived: UInt64, tabletTime: UInt64) {
        let rtt = Int64(macReceived) - Int64(macSent)
        guard rtt >= 0 else { return }
        rttMicros = rtt
        samples += 1
        // The lowest round trip has the least queueing, so its midpoint is the best estimate.
        // Let the best value age slowly so clock drift is followed.
        if samples % 30 == 0 { bestRtt = bestRtt &+ bestRtt / 4 }
        if rtt <= bestRtt {
            bestRtt = rtt
            offsetMicros = Int64(tabletTime) - (Int64(macSent) + rtt / 2)
        }
    }

    /// Age of a tablet timestamp at Mac time `macNow`, in microseconds.
    public func latency(tabletMicros: UInt64, macNow: UInt64) -> Int64? {
        guard let off = offsetMicros else { return nil }
        return Int64(macNow) - (Int64(tabletMicros) - off)
    }
}
