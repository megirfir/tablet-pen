import AppKit
import ApplicationServices
import TabletPenCore

/// Turns pipeline output into system events with CGEvent. Needs the Accessibility permission.
/// All calls happen on the input queue.
final class Injector {
    var settings: Settings
    var tabletAspect: Double = Surface.default.aspect

    private let source = CGEventSource(stateID: .hidSystemState)
    private var pos = CGPoint.zero          // our idea of the cursor, with sub-point precision
    private var posted = CGPoint(x: -1, y: -1)
    private var down: Set<MouseButton> = []
    private var lastPost = 0.0
    private var clickState = 1
    private var scrollRemX = 0.0, scrollRemY = 0.0
    private var displays: [(id: CGDirectDisplayID, rect: Rect)] = []
    private var displaysStamp = 0.0
    private(set) var lastPen: (pressure: Double, tiltX: Double, tiltY: Double) = (0, 0, 0)

    init(settings: Settings) { self.settings = settings }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func promptForAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: Displays

    private func refreshDisplays() {
        let now = ProcessInfo.processInfo.systemUptime
        if !displays.isEmpty, now - displaysStamp < 2 { return }
        displaysStamp = now
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &n)
        displays = ids.prefix(Int(n)).map { id in
            let b = CGDisplayBounds(id)      // global points, origin top-left of the main display
            return (id, Rect(x: b.origin.x, y: b.origin.y, width: b.width, height: b.height))
        }
    }

    private var targetRect: Rect {
        refreshDisplays()
        if let d = displays.first(where: { $0.id == settings.targetDisplay }) { return d.rect }
        let main = CGMainDisplayID()
        return displays.first(where: { $0.id == main })?.rect ?? displays.first?.rect
            ?? Rect(x: 0, y: 0, width: 1512, height: 982)
    }

    // MARK: Pointer

    private func syncPosition() {
        // If something else (the real trackpad) moved the cursor, continue from there. Only checked
        // after a pause: while we are posting at 240 Hz the system's reported location lags behind
        // what we posted, and trusting it would throw movement away.
        let now = ProcessInfo.processInfo.systemUptime
        defer { lastPost = now }
        guard now - lastPost > 0.15, let cur = CGEvent(source: nil)?.location else { return }
        if abs(cur.x - posted.x) > 1 || abs(cur.y - posted.y) > 1 { pos = cur }
    }

    private func postMove(dx: Double, dy: Double) {
        let type: CGEventType = down.contains(.left) ? .leftMouseDragged
            : down.contains(.right) ? .rightMouseDragged
            : down.contains(.middle) ? .otherMouseDragged : .mouseMoved
        let button: CGMouseButton = down.contains(.left) ? .left : down.contains(.right) ? .right
            : down.contains(.middle) ? .center : .left
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: pos, mouseButton: button) else { return }
        e.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx.rounded()))
        e.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy.rounded()))
        if !down.isEmpty { e.setIntegerValueField(.mouseEventClickState, value: Int64(clickState)) }
        e.post(tap: .cghidEventTap)
        posted = pos
    }

    func apply(_ event: OutputEvent) {
        switch event {
        case let .moveBy(dx, dy):
            syncPosition()
            refreshDisplays()
            let p = clampToDisplays(x: pos.x + dx, y: pos.y + dy, from: (pos.x, pos.y), displays: displays.map { $0.rect })
            let moved = (p.x - pos.x, p.y - pos.y)
            pos = CGPoint(x: p.x, y: p.y)
            postMove(dx: moved.0, dy: moved.1)

        case let .moveTo(nx, ny):
            lastPost = ProcessInfo.processInfo.systemUptime
            let m = AbsoluteMapper(tabletAspect: tabletAspect, target: targetRect, fit: settings.aspectFit)
            let p = m.map(nx: nx, ny: ny)
            let d = (p.x - pos.x, p.y - pos.y)
            pos = CGPoint(x: p.x, y: p.y)
            postMove(dx: d.0, dy: d.1)

        case let .button(button, isDown, clicks):
            syncPosition()
            let type: CGEventType
            let cg: CGMouseButton
            switch button {
            case .left: type = isDown ? .leftMouseDown : .leftMouseUp; cg = .left
            case .right: type = isDown ? .rightMouseDown : .rightMouseUp; cg = .right
            case .middle: type = isDown ? .otherMouseDown : .otherMouseUp; cg = .center
            }
            if isDown { down.insert(button) } else { down.remove(button) }
            clickState = max(clicks, 1)
            guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: pos, mouseButton: cg) else { return }
            e.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
            e.post(tap: .cghidEventTap)
            posted = pos

        case let .scroll(dx, dy, phase, momentum):
            let sign = settings.naturalScroll ? 1.0 : -1.0
            scrollRemX += dx * sign; scrollRemY += dy * sign
            let ix = scrollRemX.rounded(.towardZero), iy = scrollRemY.rounded(.towardZero)
            scrollRemX -= ix; scrollRemY -= iy
            if phase == .began || momentum == .begin { scrollRemX = 0; scrollRemY = 0 }
            // Skip empty in-between events, but always deliver phase transitions.
            if ix == 0, iy == 0, phase == .changed || momentum == .continuing { return }
            guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                  wheel1: Int32(iy), wheel2: Int32(ix), wheel3: 0) else { return }
            e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            e.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
            e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue))
            e.post(tap: .cghidEventTap)

        case let .magnify(delta, phase):
            postMagnify(delta, phase)

        case let .pen(pressure, tiltX, tiltY, _, _):
            lastPen = (pressure, tiltX, tiltY)      // used for tablet events in drawing mode (M5)
        }
    }

    /// There is no public API for pinch events. This builds the same gesture event the trackpad
    /// driver produces (event type 29 = NSEventTypeGesture, subtype 8 = magnify). The field
    /// numbers are undocumented but have been stable for many macOS releases.
    private func postMagnify(_ delta: Double, _ phase: Phase) {
        guard let e = CGEvent(source: source) else { return }
        e.type = CGEventType(rawValue: 29)!
        e.setIntegerValueField(CGEventField(rawValue: 110)!, value: 8)                     // gesture subtype: magnify
        e.setIntegerValueField(CGEventField(rawValue: 132)!, value: Int64(phase.rawValue)) // gesture phase
        e.setDoubleValueField(CGEventField(rawValue: 113)!, value: delta)                  // magnification
        e.post(tap: .cghidEventTap)
    }

    /// Releases anything still held (disconnect, quit).
    func releaseAll() {
        for b in down { apply(.button(b, down: false, clicks: 1)) }
    }
}
