import Foundation

public enum MouseButton: Int, Sendable { case left = 0, right = 1, middle = 2 }

/// Values match CGScrollPhase / the gesture phase bits macOS uses.
public enum Phase: Int, Sendable { case none = 0, began = 1, changed = 2, ended = 4 }

/// Values match CGMomentumScrollPhase.
public enum MomentumPhase: Int, Sendable { case none = 0, begin = 1, continuing = 2, end = 3 }

/// What the input pipeline asks the Mac to do. The app's injector turns these into CGEvents;
/// tests inspect them directly.
public enum OutputEvent: Equatable, Sendable {
    /// Relative cursor movement in screen points.
    case moveBy(dx: Double, dy: Double)
    /// Absolute position on the normalized tablet surface (mapped to a screen by the injector).
    case moveTo(nx: Double, ny: Double)
    case button(MouseButton, down: Bool, clicks: Int)
    /// Scroll in points. dx/dy follow the fingers (dy > 0 = fingers moved down).
    case scroll(dx: Double, dy: Double, phase: Phase, momentum: MomentumPhase)
    /// Pinch. delta is the change in magnification (0.1 = 10 % larger).
    case magnify(delta: Double, phase: Phase)
    /// Pen state for tablet events: curved pressure 0...1 and curved tilt in degrees.
    case pen(pressure: Double, tiltX: Double, tiltY: Double, inContact: Bool, inProximity: Bool)
}

/// Turns finger samples into trackpad behaviour: move, tap-to-click, two-finger tap (right-click),
/// two-finger scroll with momentum, pinch zoom, three-finger drag and tap-and-drag.
/// Pure logic with explicit timestamps (seconds) so it can be unit tested and replayed.
public final class GestureRecognizer {
    public var settings: Settings
    public var surface: Surface

    // Tunables (inches / seconds)
    let moveSlop = 0.02            // travel before the cursor starts to follow (filters touch jitter)
    let tapSlop = 0.05             // travel that disqualifies a touch from being a tap
    let tapNearby = 0.6            // a second tap / tap-and-drag must land this close to the first
    let bounceGap = 0.04           // a touch landing this soon after a lift is contact bounce, not a tap
    let scrollSlop = 0.05
    let zoomSlop = 0.12
    let tapMaxDuration = 0.25
    let multiTapWindow = 0.35
    let tapDragWindow = 0.25
    let scrollPointsPerInch = 450.0
    let zoomPerInch = 0.5
    let momentumTimeConstant = 0.325
    let momentumMinSpeed = 120.0     // points/s needed to start
    let momentumStopSpeed = 25.0

    private struct Touch { var x, y, startX, startY: Double }
    private enum TwoMode { case undecided, scroll, zoom }
    private enum Drag { case none, tap, threeFinger }

    private var touches: [UInt8: Touch] = [:]
    private var sessionStart = 0.0
    private var maxTouches = 0
    private var moved = false       // tap disqualified
    private var moving = false      // cursor is following the finger
    private var bounce = false
    private var lastLiftTime = -10.0
    private var lastTapX = 0.0, lastTapY = 0.0
    private var twoMode = TwoMode.undecided
    private var twoStartSpread = 0.0
    private var lastSpread = 0.0
    private var panX = 0.0, panY = 0.0
    private var drag = Drag.none
    private var pendingTapDrag = false
    private var lastTapTime = -10.0
    private var lastTapButton = MouseButton.left
    private var lastTapCount = 0
    private var lastMoveTime = 0.0
    private var speed = 0.0
    private var scrollHistory: [(t: Double, dx: Double, dy: Double)] = []
    private var momentum: (vx: Double, vy: Double, last: Double?, started: Bool)?

    public init(settings: Settings = Settings(), surface: Surface = .default) {
        self.settings = settings; self.surface = surface
    }

    public var isIdle: Bool { touches.isEmpty && momentum == nil && drag == .none }
    public var hasMomentum: Bool { momentum != nil }

    private func centroid() -> (x: Double, y: Double) {
        let n = Double(max(touches.count, 1))
        return (touches.values.reduce(0) { $0 + $1.x } / n, touches.values.reduce(0) { $0 + $1.y } / n)
    }

    private func spread() -> Double {
        let c = centroid()
        return touches.values.reduce(0) { $0 + hypot($1.x - c.x, $1.y - c.y) } / Double(max(touches.count, 1)) * 2
    }

    private func gain(_ dx: Double, _ dy: Double, _ t: Double) -> OutputEvent {
        let dt = t - lastMoveTime
        if dt > 0 {
            let inst = hypot(dx, dy) / dt
            speed = dt > 0.1 ? inst : speed * 0.6 + inst * 0.4
            lastMoveTime = t
        }
        let g = pointerGain(speedInPerSec: speed, sensitivity: settings.sensitivity, acceleration: settings.acceleration)
        return .moveBy(dx: dx * g, dy: dy * g)
    }

    private func stopMomentum() -> [OutputEvent] {
        guard let m = momentum else { return [] }
        momentum = nil
        return m.started ? [.scroll(dx: 0, dy: 0, phase: .none, momentum: .end)] : []
    }

    private func endTwoFinger(_ t: Double, cancelled: Bool) -> [OutputEvent] {
        defer { twoMode = .undecided; scrollHistory.removeAll() }
        switch twoMode {
        case .undecided: return []
        case .zoom: return [.magnify(delta: 0, phase: .ended)]
        case .scroll:
            var out: [OutputEvent] = [.scroll(dx: 0, dy: 0, phase: .ended, momentum: .none)]
            let recent = scrollHistory.filter { t - $0.t <= 0.08 }
            if !cancelled, settings.momentumScroll, let first = recent.first, let last = recent.last,
               t - last.t < 0.05 {
                let span = max(last.t - first.t, 0.008)
                let vx = recent.dropFirst().reduce(0) { $0 + $1.dx } / span
                let vy = recent.dropFirst().reduce(0) { $0 + $1.dy } / span
                if recent.count >= 3, hypot(vx, vy) > momentumMinSpeed {
                    momentum = (vx, vy, nil, false)
                }
            }
            if momentum == nil { out += [] }
            return out
        }
    }

    public func handle(_ s: Sample, time t: Double) -> [OutputEvent] {
        var out: [OutputEvent] = []
        let x = s.nx * surface.widthIn, y = s.ny * surface.heightIn

        switch s.action {
        case .down:
            out += stopMomentum()
            if touches.isEmpty {
                sessionStart = t; maxTouches = 0; moved = false; moving = false; twoMode = .undecided
                bounce = t - lastLiftTime < bounceGap
                pendingTapDrag = !bounce && settings.tapToClick && settings.tapAndDrag && lastTapButton == .left
                    && lastTapCount > 0 && t - lastTapTime < tapDragWindow
                    && hypot(x - lastTapX, y - lastTapY) < tapNearby
                lastMoveTime = t; speed = 0
            }
            touches[s.pointerId] = Touch(x: x, y: y, startX: x, startY: y)
            maxTouches = max(maxTouches, touches.count)
            if touches.count >= 2 { pendingTapDrag = false }
            if touches.count == 2 {
                if twoMode != .undecided { out += endTwoFinger(t, cancelled: true) }
                twoStartSpread = spread(); lastSpread = twoStartSpread; panX = 0; panY = 0
            } else if touches.count > 2, twoMode != .undecided {
                out += endTwoFinger(t, cancelled: true)
            }
            if touches.count == 3 { panX = 0; panY = 0 }

        case .move:
            guard var touch = touches[s.pointerId] else { break }
            let before = centroid()
            touch.x = x; touch.y = y
            touches[s.pointerId] = touch
            let after = centroid()
            let dx = after.x - before.x, dy = after.y - before.y

            switch touches.count {
            case 1:
                let travel = hypot(x - touch.startX, y - touch.startY)
                if !moving {
                    guard travel >= moveSlop else { break }
                    moving = true
                    lastMoveTime = t
                    if pendingTapDrag {
                        out.append(.button(.left, down: true, clicks: 1))
                        drag = .tap; moved = true
                    }
                    break   // swallow the slop so the cursor does not jump
                }
                if travel >= tapSlop { moved = true }
                if settings.fingerMode == .absolute, drag == .none {
                    out.append(.moveTo(nx: s.nx, ny: s.ny))
                } else {
                    out.append(gain(dx, dy, t))
                }

            case 2:
                panX += dx; panY += dy
                let sp = spread()
                if twoMode == .undecided {
                    let dSpread = abs(sp - twoStartSpread), pan = hypot(panX, panY)
                    if settings.pinchZoom, dSpread > zoomSlop, dSpread > pan * 1.5 {
                        twoMode = .zoom; moved = true; lastSpread = sp
                        out.append(.magnify(delta: 0, phase: .began))
                    } else if pan > scrollSlop {
                        twoMode = .scroll; moved = true
                        out.append(.scroll(dx: 0, dy: 0, phase: .began, momentum: .none))
                        scrollHistory = [(t, 0, 0)]
                    }
                    break
                }
                if twoMode == .scroll {
                    let k = scrollPointsPerInch * settings.scrollSpeed
                    let sx = dx * k, sy = dy * k
                    if sx != 0 || sy != 0 {
                        out.append(.scroll(dx: sx, dy: sy, phase: .changed, momentum: .none))
                        if let last = scrollHistory.last, last.t == t {
                            scrollHistory[scrollHistory.count - 1] = (t, last.dx + sx, last.dy + sy)
                        } else {
                            scrollHistory.append((t, sx, sy))
                            if scrollHistory.count > 64 { scrollHistory.removeFirst(32) }
                        }
                    }
                } else {
                    let d = (sp - lastSpread) * zoomPerInch
                    lastSpread = sp
                    if d != 0 { out.append(.magnify(delta: d, phase: .changed)) }
                }

            case 3 where settings.threeFingerDrag:
                if drag != .threeFinger {
                    panX += dx; panY += dy
                    guard hypot(panX, panY) >= moveSlop else { break }
                    moved = true; drag = .threeFinger; lastMoveTime = t
                    out.append(.button(.left, down: true, clicks: 1))
                    break
                }
                out.append(gain(dx, dy, t))

            default: break
            }

        case .up, .cancel:
            guard touches.removeValue(forKey: s.pointerId) != nil else { break }
            let cancelled = s.action == .cancel
            if touches.count < 2, twoMode != .undecided { out += endTwoFinger(t, cancelled: cancelled) }
            if touches.isEmpty {
                if drag != .none {
                    out.append(.button(.left, down: false, clicks: 1))
                    drag = .none
                    lastTapCount = 0
                } else if !cancelled, !moved, !bounce, settings.tapToClick, t - sessionStart <= tapMaxDuration,
                          (1...3).contains(maxTouches) {
                    let button: MouseButton = maxTouches == 1 ? .left : (maxTouches == 2 ? .right : .middle)
                    let count = (button == lastTapButton && lastTapCount > 0 && t - lastTapTime < multiTapWindow
                                 && hypot(x - lastTapX, y - lastTapY) < tapNearby) ? lastTapCount + 1 : 1
                    lastTapX = x; lastTapY = y
                    out.append(.button(button, down: true, clicks: count))
                    out.append(.button(button, down: false, clicks: count))
                    lastTapTime = t; lastTapButton = button; lastTapCount = count
                } else if !bounce {
                    lastTapCount = 0
                }
                pendingTapDrag = false
                lastLiftTime = t
            }

        case .hoverMove, .hoverEnter, .hoverExit:
            break
        }
        return out
    }

    /// Drives momentum scrolling. Call at display rate with a monotonic clock (seconds).
    public func tick(now: Double) -> [OutputEvent] {
        guard var m = momentum else { return [] }
        let dt = min(max(m.last.map { now - $0 } ?? (1.0 / 120), 0), 0.05)
        m.last = now
        let decay = exp(-dt / momentumTimeConstant)
        m.vx *= decay; m.vy *= decay
        if hypot(m.vx, m.vy) < momentumStopSpeed {
            momentum = nil
            return m.started ? [.scroll(dx: 0, dy: 0, phase: .none, momentum: .end)] : []
        }
        let phase: MomentumPhase = m.started ? .continuing : .begin
        m.started = true
        momentum = m
        return [.scroll(dx: m.vx * dt, dy: m.vy * dt, phase: .none, momentum: phase)]
    }

    /// Drops all touches and releases anything held (palm rejection, disconnect, mode switch).
    public func cancelAll() -> [OutputEvent] {
        var out = stopMomentum()
        if twoMode == .scroll { out.append(.scroll(dx: 0, dy: 0, phase: .ended, momentum: .none)) }
        if twoMode == .zoom { out.append(.magnify(delta: 0, phase: .ended)) }
        if drag != .none { out.append(.button(.left, down: false, clicks: 1)) }
        touches.removeAll(); twoMode = .undecided; drag = .none; pendingTapDrag = false
        lastTapCount = 0; scrollHistory.removeAll()
        return out
    }
}
