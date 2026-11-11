import Foundation
import Testing
@testable import TabletPenCore

// Surface of 10 x 6 inches makes normalized → inches easy to reason about.
let surf = Surface(widthIn: 10, heightIn: 6)

func finger(_ a: Action, id: UInt8 = 0, x: Double, y: Double) -> Sample {
    Sample(dtMicros: 0, pointerId: id, tool: .finger, action: a, flags: a == .up ? [] : .contact,
           x: UInt16(x / 10 * 65535), y: UInt16(y / 6 * 65535), pressure: 65535, tiltX: 0, tiltY: 0, orientation: 0)
}

func pen(_ a: Action, x: Double, y: Double, p: Double = 0.6) -> Sample {
    Sample(dtMicros: 0, pointerId: 0, tool: .pen, action: a, flags: [],
           x: UInt16(x / 10 * 65535), y: UInt16(y / 6 * 65535), pressure: UInt16(p * 65535), tiltX: 0, tiltY: 0, orientation: 0)
}

extension Array where Element == OutputEvent {
    var buttons: [OutputEvent] { filter { if case .button = $0 { return true }; return false } }
    var moves: [(Double, Double)] { compactMap { if case let .moveBy(dx, dy) = $0 { return (dx, dy) }; return nil } }
    var scrolls: [(dx: Double, dy: Double, phase: Phase, momentum: MomentumPhase)] {
        compactMap { if case let .scroll(dx, dy, p, m) = $0 { return (dx, dy, p, m) }; return nil }
    }
    var magnifies: [(Double, Phase)] { compactMap { if case let .magnify(d, p) = $0 { return (d, p) }; return nil } }
}

@Suite struct GestureTests {
    let g = GestureRecognizer(settings: Settings(), surface: surf)

    @Test func oneFingerMovesCursorAndDoesNotClick() {
        var out = g.handle(finger(.down, x: 5, y: 3), time: 0)
        for i in 1...20 { out += g.handle(finger(.move, x: 5 + Double(i) * 0.05, y: 3), time: Double(i) * 0.008) }
        out += g.handle(finger(.up, x: 6, y: 3), time: 0.2)
        #expect(out.buttons.isEmpty)
        let total = out.moves.reduce(0) { $0 + $1.0 }
        #expect(total > 250)                       // ~0.95 in at >= 300 pt/in
        #expect(out.moves.allSatisfy { $0.0 > 0 && $0.1 == 0 })
    }

    @Test func tapClicksLeft() {
        var out = g.handle(finger(.down, x: 5, y: 3), time: 0)
        out += g.handle(finger(.move, x: 5.01, y: 3), time: 0.02)   // within slop
        out += g.handle(finger(.up, x: 5.01, y: 3), time: 0.08)
        #expect(out == [.button(.left, down: true, clicks: 1), .button(.left, down: false, clicks: 1)])
    }

    @Test func slowPressIsNotATap() {
        var out = g.handle(finger(.down, x: 5, y: 3), time: 0)
        out += g.handle(finger(.up, x: 5, y: 3), time: 0.6)
        #expect(out.isEmpty)
    }

    @Test func doubleTapIsDoubleClick() {
        var out = g.handle(finger(.down, x: 5, y: 3), time: 0)
        out += g.handle(finger(.up, x: 5, y: 3), time: 0.05)
        out += g.handle(finger(.down, x: 5, y: 3), time: 0.15)
        out += g.handle(finger(.up, x: 5, y: 3), time: 0.20)
        #expect(out.buttons.last == .button(.left, down: false, clicks: 2))
    }

    @Test func contactBounceIsNotADoubleClick() {
        var out = g.handle(finger(.down, x: 5, y: 3), time: 0)
        out += g.handle(finger(.up, x: 5, y: 3), time: 0.06)
        out += g.handle(finger(.down, x: 5, y: 3), time: 0.075)     // 15 ms later: bounce
        out += g.handle(finger(.up, x: 5, y: 3), time: 0.10)
        #expect(out == [.button(.left, down: true, clicks: 1), .button(.left, down: false, clicks: 1)])
    }

    @Test func tapsFarApartAreTwoSingleClicks() {
        var out = g.handle(finger(.down, x: 2, y: 3), time: 0)
        out += g.handle(finger(.up, x: 2, y: 3), time: 0.05)
        out += g.handle(finger(.down, x: 7, y: 3), time: 0.2)
        out += g.handle(finger(.up, x: 7, y: 3), time: 0.25)
        #expect(out.buttons.map { e -> Int in if case let .button(_, _, c) = e { return c }; return 0 } == [1, 1, 1, 1])
    }

    @Test func tapThenMovingElsewhereOrLaterDoesNotDrag() {
        // Elsewhere on the pad.
        var out = g.handle(finger(.down, x: 2, y: 3), time: 0)
        out += g.handle(finger(.up, x: 2, y: 3), time: 0.05)
        out += g.handle(finger(.down, x: 7, y: 3), time: 0.15)
        for i in 1...10 { out += g.handle(finger(.move, x: 7 + Double(i) * 0.05, y: 3), time: 0.15 + Double(i) * 0.008) }
        out += g.handle(finger(.up, x: 7.5, y: 3), time: 0.5)
        #expect(out.buttons.count == 2 && !out.moves.isEmpty)
        // Same place, but after the tap-and-drag window.
        let g2 = GestureRecognizer(settings: Settings(), surface: surf)
        var o2 = g2.handle(finger(.down, x: 5, y: 3), time: 0)
        o2 += g2.handle(finger(.up, x: 5, y: 3), time: 0.05)
        o2 += g2.handle(finger(.down, x: 5, y: 3), time: 0.35)
        for i in 1...10 { o2 += g2.handle(finger(.move, x: 5 + Double(i) * 0.05, y: 3), time: 0.35 + Double(i) * 0.008) }
        o2 += g2.handle(finger(.up, x: 5.5, y: 3), time: 0.7)
        #expect(o2.buttons.count == 2 && !o2.moves.isEmpty)
    }

    @Test func cursorStartsFollowingAfterAVerySmallMove() {
        var out = g.handle(finger(.down, x: 5, y: 3), time: 0)
        out += g.handle(finger(.move, x: 5.025, y: 3), time: 0.008)
        out += g.handle(finger(.move, x: 5.035, y: 3), time: 0.016)
        #expect(out.moves.count == 1)
    }

    @Test func twoFingerTapRightClicks() {
        var out = g.handle(finger(.down, id: 0, x: 4, y: 3), time: 0)
        out += g.handle(finger(.down, id: 1, x: 5, y: 3), time: 0.01)
        out += g.handle(finger(.up, id: 1, x: 5, y: 3), time: 0.08)
        out += g.handle(finger(.up, id: 0, x: 4, y: 3), time: 0.09)
        #expect(out == [.button(.right, down: true, clicks: 1), .button(.right, down: false, clicks: 1)])
    }

    @Test func tapAndDragHoldsLeftButton() {
        var out = g.handle(finger(.down, x: 5, y: 3), time: 0)
        out += g.handle(finger(.up, x: 5, y: 3), time: 0.05)
        out += g.handle(finger(.down, x: 5, y: 3), time: 0.15)
        for i in 1...10 { out += g.handle(finger(.move, x: 5 + Double(i) * 0.05, y: 3), time: 0.15 + Double(i) * 0.008) }
        out += g.handle(finger(.up, x: 5.5, y: 3), time: 0.5)
        #expect(out.buttons == [.button(.left, down: true, clicks: 1), .button(.left, down: false, clicks: 1),
                                .button(.left, down: true, clicks: 1), .button(.left, down: false, clicks: 1)])
        #expect(!out.moves.isEmpty)
    }

    func twoFingerScroll(dyPerStep: Double, steps: Int, dt: Double = 0.008) -> (out: [OutputEvent], end: Double) {
        var out = g.handle(finger(.down, id: 0, x: 4, y: 2), time: 0)
        out += g.handle(finger(.down, id: 1, x: 5, y: 2), time: 0)
        var t = 0.0
        for i in 1...steps {
            t = Double(i) * dt
            out += g.handle(finger(.move, id: 0, x: 4, y: 2 + Double(i) * dyPerStep), time: t)
            out += g.handle(finger(.move, id: 1, x: 5, y: 2 + Double(i) * dyPerStep), time: t)
        }
        return (out, t)
    }

    @Test func twoFingerScrollHasPhasesAndNoClick() {
        var (out, t) = twoFingerScroll(dyPerStep: 0.03, steps: 30)
        out += g.handle(finger(.up, id: 0, x: 4, y: 2.9), time: t + 0.3)   // paused before lifting
        out += g.handle(finger(.up, id: 1, x: 5, y: 2.9), time: t + 0.3)
        let s = out.scrolls
        #expect(s.first?.phase == .began)
        #expect(s.last?.phase == .ended)
        #expect(s.filter { $0.phase == .changed }.allSatisfy { $0.dy > 0 && abs($0.dx) < 1e-9 })
        let total = s.reduce(0) { $0 + $1.dy }
        #expect(abs(total - (0.9 - 0.06) * 450) < 30)     // travel minus the slop steps, 450 pt/in
        #expect(out.buttons.isEmpty && out.moves.isEmpty && out.magnifies.isEmpty)
        #expect(!g.hasMomentum)
    }

    @Test func flickStartsMomentumThatDecaysAndEnds() {
        var (out, t) = twoFingerScroll(dyPerStep: 0.06, steps: 20)
        out += g.handle(finger(.up, id: 0, x: 4, y: 3.2), time: t + 0.004)
        out += g.handle(finger(.up, id: 1, x: 5, y: 3.2), time: t + 0.004)
        #expect(g.hasMomentum)
        var m: [OutputEvent] = []
        var now = 100.0
        for _ in 0..<2000 where g.hasMomentum { m += g.tick(now: now); now += 1.0 / 120 }
        let s = m.scrolls
        #expect(s.first?.momentum == .begin)
        #expect(s.last?.momentum == .end)
        #expect(s.dropFirst().dropLast().allSatisfy { $0.momentum == .continuing })
        let deltas = s.dropLast().map { $0.dy }
        #expect(deltas.allSatisfy { $0 > 0 })
        #expect(zip(deltas, deltas.dropFirst()).allSatisfy { $1 <= $0 + 1e-9 })   // monotonic decay
        #expect(now - 100 < 3)                                                   // finishes within 3 s
    }

    @Test func newTouchStopsMomentum() {
        var (out, t) = twoFingerScroll(dyPerStep: 0.06, steps: 20)
        out += g.handle(finger(.up, id: 0, x: 4, y: 3.2), time: t + 0.004)
        out += g.handle(finger(.up, id: 1, x: 5, y: 3.2), time: t + 0.004)
        _ = g.tick(now: 1); _ = g.tick(now: 1.01)
        let stop = g.handle(finger(.down, x: 5, y: 3), time: t + 0.1)
        #expect(stop.scrolls.last?.momentum == .end)
        #expect(!g.hasMomentum)
    }

    @Test func pinchZoomsInAndOut() {
        var out = g.handle(finger(.down, id: 0, x: 4.5, y: 3), time: 0)
        out += g.handle(finger(.down, id: 1, x: 5.5, y: 3), time: 0)
        for i in 1...30 {
            let d = Double(i) * 0.03
            out += g.handle(finger(.move, id: 0, x: 4.5 - d, y: 3), time: Double(i) * 0.008)
            out += g.handle(finger(.move, id: 1, x: 5.5 + d, y: 3), time: Double(i) * 0.008)
        }
        out += g.handle(finger(.up, id: 0, x: 3.6, y: 3), time: 0.3)
        out += g.handle(finger(.up, id: 1, x: 6.4, y: 3), time: 0.3)
        let z = out.magnifies
        #expect(z.first?.1 == .began && z.last?.1 == .ended)
        #expect(z.reduce(0) { $0 + $1.0 } > 0.5)
        #expect(out.scrolls.isEmpty && out.buttons.isEmpty)
    }

    @Test func threeFingerDragHoldsButtonUntilAllLift() {
        var out: [OutputEvent] = []
        for id in 0..<3 { out += g.handle(finger(.down, id: UInt8(id), x: 4 + Double(id), y: 3), time: 0) }
        for i in 1...15 {
            for id in 0..<3 {
                out += g.handle(finger(.move, id: UInt8(id), x: 4 + Double(id) + Double(i) * 0.04, y: 3), time: Double(i) * 0.008)
            }
        }
        #expect(out.buttons == [.button(.left, down: true, clicks: 1)])
        out += g.handle(finger(.up, id: 0, x: 4.6, y: 3), time: 0.4)
        out += g.handle(finger(.up, id: 1, x: 5.6, y: 3), time: 0.4)
        #expect(out.buttons.count == 1)
        out += g.handle(finger(.up, id: 2, x: 6.6, y: 3), time: 0.41)
        #expect(out.buttons.last == .button(.left, down: false, clicks: 1))
        #expect(out.moves.reduce(0) { $0 + $1.0 } > 100)
    }

    @Test func cancelReleasesEverything() {
        var out = g.handle(finger(.down, x: 5, y: 3), time: 0)
        out += g.handle(finger(.up, x: 5, y: 3), time: 0.05)
        out += g.handle(finger(.down, x: 5, y: 3), time: 0.15)
        out += g.handle(finger(.move, x: 5.3, y: 3), time: 0.2)
        let c = g.cancelAll()
        #expect(c == [.button(.left, down: false, clicks: 1)])
        #expect(g.isIdle)
    }

    @Test func systemCancelDoesNotClick() {
        var out = g.handle(finger(.down, x: 5, y: 3), time: 0)
        out += g.handle(finger(.cancel, x: 5, y: 3), time: 0.05)
        #expect(out.isEmpty)
    }
}

@Suite struct PenTests {
    @Test func absoluteHoverMovesAndContactDrags() {
        let p = PenTracker(settings: Settings(), surface: surf)
        var out = p.handle(pen(.hoverEnter, x: 5, y: 3), time: 0)
        out += p.handle(pen(.hoverMove, x: 6, y: 3), time: 0.01)
        out += p.handle(pen(.down, x: 6, y: 3), time: 0.02)
        out += p.handle(pen(.move, x: 7, y: 3), time: 0.03)
        out += p.handle(pen(.up, x: 7, y: 3), time: 0.04)
        let pos = out.compactMap { e -> Double? in if case let .moveTo(nx, _) = e { return nx }; return nil }
        #expect(pos.count == 4 && abs(pos[1] - 0.6) < 1e-3 && abs(pos[3] - 0.7) < 1e-3)
        #expect(out.buttons == [.button(.left, down: true, clicks: 1), .button(.left, down: false, clicks: 1)])
    }

    @Test func tipWobbleDuringClickIsNotADrag() {
        let p = PenTracker(settings: Settings(), surface: surf)
        var out = p.handle(pen(.down, x: 5, y: 3), time: 0)
        let before = out.count
        out += p.handle(pen(.move, x: 5.01, y: 3.005), time: 0.01)
        #expect(!out.dropFirst(before).contains { if case .moveTo = $0 { return true }; return false })
    }

    @Test func relativeModeUsesDeltas() {
        var s = Settings(); s.penMode = .relative
        let p = PenTracker(settings: s, surface: surf)
        var out = p.handle(pen(.hoverEnter, x: 5, y: 3), time: 0)
        out += p.handle(pen(.hoverMove, x: 5.1, y: 3), time: 0.004)
        out += p.handle(pen(.hoverMove, x: 5.2, y: 3), time: 0.008)
        #expect(out.moves.count == 2 && out.moves.allSatisfy { $0.0 > 0 })
        #expect(!out.contains { if case .moveTo = $0 { return true }; return false })
    }

    @Test func tipBounceIsNotADoubleClick() {
        let p = PenTracker(settings: Settings(), surface: surf)
        var out = p.handle(pen(.down, x: 5, y: 3), time: 0)
        out += p.handle(pen(.up, x: 5, y: 3), time: 0.05)
        out += p.handle(pen(.down, x: 5, y: 3), time: 0.06)
        out += p.handle(pen(.up, x: 5, y: 3), time: 0.10)
        #expect(out.buttons.allSatisfy { if case let .button(_, _, c) = $0 { return c == 1 }; return false })
        // A deliberate second tap still double-clicks.
        out = p.handle(pen(.down, x: 5, y: 3), time: 0.30)
        #expect(out.buttons == [.button(.left, down: true, clicks: 2)])
    }

    @Test func sideButtonRightClicks() {
        let p = PenTracker()
        #expect(p.button(kind: 1) == [.button(.right, down: true, clicks: 1), .button(.right, down: false, clicks: 1)])
        #expect(p.button(kind: 2).isEmpty)
    }

    @Test func pressureIsCurvedAndZeroWhenHovering() {
        let p = PenTracker(settings: Settings(), surface: surf)
        let hover = p.handle(pen(.hoverMove, x: 5, y: 3, p: 0.5), time: 0)
        let down = p.handle(pen(.down, x: 5, y: 3, p: 0.6), time: 0.01)
        func pr(_ e: [OutputEvent]) -> Double? { e.compactMap { if case let .pen(pp, _, _, _, _) = $0 { return pp }; return nil }.first }
        #expect(pr(hover) == 0)
        #expect(abs(pr(down)! - 0.5) < 0.05)
    }
}

@Suite struct PipelineTests {
    @Test func palmIsIgnoredWhilePenIsNear() {
        let pipe = InputPipeline(settings: Settings(), surface: surf)
        var out = pipe.handle(.input(baseMicros: 0, samples: [pen(.hoverEnter, x: 5, y: 3)]))
        out += pipe.handle(.input(baseMicros: 10_000, samples: [finger(.down, x: 8, y: 5)]))
        out += pipe.handle(.input(baseMicros: 20_000, samples: [finger(.up, x: 8, y: 5)]))
        #expect(out.buttons.isEmpty)
    }

    @Test func penArrivalCancelsFingerDrag() {
        let pipe = InputPipeline(settings: Settings(), surface: surf)
        var out: [OutputEvent] = []
        var t: UInt64 = 0
        for id in 0..<3 { out += pipe.handle(.input(baseMicros: t, samples: [finger(.down, id: UInt8(id), x: 4 + Double(id), y: 3)])) }
        for i in 1...10 {
            t += 8000
            out += pipe.handle(.input(baseMicros: t, samples: (0..<3).map { finger(.move, id: UInt8($0), x: 4 + Double($0) + Double(i) * 0.05, y: 3) }))
        }
        #expect(out.buttons == [.button(.left, down: true, clicks: 1)])
        t += 8000
        out += pipe.handle(.input(baseMicros: t, samples: [pen(.hoverEnter, x: 1, y: 1)]))
        #expect(out.buttons.last == .button(.left, down: false, clicks: 1))
    }

    @Test func helloSetsSurface() {
        let pipe = InputPipeline()
        _ = pipe.handle(.hello(version: 1, role: 0, width: 2730, height: 1365, refreshX10: 1440, dpi: 273, name: "t"))
        #expect(abs(pipe.surface.widthIn - 10) < 1e-9 && abs(pipe.surface.heightIn - 5) < 1e-9)
    }
}

@Suite struct MappingTests {
    let screen = Rect(x: 0, y: 0, width: 1512, height: 982)      // 14" MacBook Pro, aspect 1.54

    @Test func stretchMapsCornersToCorners() {
        let m = AbsoluteMapper(tabletAspect: 1.6, target: screen, fit: .stretch)
        #expect(m.map(nx: 0, ny: 0) == (0, 0))
        let br = m.map(nx: 1, ny: 1)
        #expect(br.x == 1511 && br.y == 981)
    }

    @Test func letterboxKeepsShapeAndReachesWholeScreen() {
        let m = AbsoluteMapper(tabletAspect: 1.6, target: screen, fit: .letterbox)
        let a = m.activeTabletArea
        #expect(a.width < 1 && a.height == 1)
        // Active tablet area has the screen's aspect ratio.
        #expect(abs((a.width * 1.6) / a.height - 1512.0 / 982.0) < 1e-9)
        #expect(m.map(nx: a.x, ny: 0).x == 0)
        #expect(abs(m.map(nx: a.x + a.width, ny: 1).x - 1511) < 1e-6)
        #expect(m.map(nx: 0, ny: 0.5).x == 0)          // unused band clamps to the edge
        // A 1-inch square stays square: equal tablet inches → equal screen points.
        let dx = m.map(nx: 0.5 + 1 / 10.0, ny: 0.5).x - m.map(nx: 0.5, ny: 0.5).x      // 1 in on a 10 in wide tablet
        let dy = m.map(nx: 0.5, ny: 0.5 + 1.6 / 10.0).y - m.map(nx: 0.5, ny: 0.5).y    // 1 in on a 6.25 in tall tablet
        #expect(abs(dx - dy) < 1.5)
    }

    @Test func cropUsesWholeTabletButNotWholeScreen() {
        let m = AbsoluteMapper(tabletAspect: 1.6, target: screen, fit: .crop)
        let r = m.reachableTarget
        #expect(r.width == 1512 && r.height < 982)
        #expect(abs(r.width / r.height - 1.6) < 1e-9)
        #expect(m.map(nx: 0, ny: 0).y == r.y)
    }

    @Test func secondDisplayOffsetIsRespected() {
        let ext = Rect(x: 1512, y: -200, width: 2560, height: 1440)
        let m = AbsoluteMapper(tabletAspect: 16.0 / 9.0, target: ext, fit: .stretch)
        let c = m.map(nx: 0.5, ny: 0.5)
        #expect(abs(c.x - (1512 + 1279.5)) < 1e-6 && abs(c.y - (-200 + 719.5)) < 1e-6)
    }

    @Test func relativeMovesCrossDisplaysButNotOffTheDesktop() {
        let a = Rect(x: 0, y: 0, width: 1512, height: 982), b = Rect(x: 1512, y: 0, width: 1920, height: 1080)
        #expect(clampToDisplays(x: 1600, y: 500, from: (1500, 500), displays: [a, b]) == (1600, 500))
        #expect(clampToDisplays(x: -50, y: 500, from: (10, 500), displays: [a, b]) == (0, 500))
        #expect(clampToDisplays(x: 800, y: 1050, from: (800, 900), displays: [a, b]) == (800, 981))
    }
}

@Suite struct CurveTests {
    @Test func pressureCurveIsMonotonicAndClamped() {
        let c = PressureCurve()
        #expect(c.apply(0) == 0 && c.apply(0.02) == 0 && c.apply(0.9) == 1 && c.apply(1) == 1)
        var last = -1.0
        for i in 0...100 { let v = c.apply(Double(i) / 100); #expect(v >= last); last = v }
        #expect(abs(c.apply(0.6) - 0.5) < 0.05)     // measured writing pressure lands mid-range
    }

    @Test func calibrationPutsMediumAtHalf() {
        let c = PressureCurve.calibrated(light: 0.05, medium: 0.4, hard: 0.8)
        #expect(abs(c.apply(0.4) - 0.5) < 1e-6)
        #expect(c.apply(0.8) == 1)
        #expect(c.apply(0.05) < 0.05)
    }

    @Test func tiltDeadZoneIgnoresNaturalGrip() {
        let t = TiltCurve()
        #expect(t.apply(tiltX: 32, tiltY: 32) == (0, 0))            // ~45° writing grip
        let lean = t.apply(tiltX: 60, tiltY: 0)
        #expect(lean.x > 0 && lean.y == 0 && lean.x < 60)
        let full = t.apply(tiltX: 0, tiltY: -80)
        #expect(full.x == 0 && abs(full.y + 60) < 1e-9)              // direction kept, clamped at output max
    }

    @Test func accelerationIsMonotonicAndOffAtZero() {
        #expect(pointerGain(speedInPerSec: 0, sensitivity: 1, acceleration: 1) == 300)
        #expect(pointerGain(speedInPerSec: 20, sensitivity: 1, acceleration: 0) == 300)
        var last = 0.0
        for v in stride(from: 0.0, through: 40, by: 0.5) {
            let g = pointerGain(speedInPerSec: v, sensitivity: 1.5, acceleration: 1)
            #expect(g >= last); last = g
        }
    }

    @Test func clockSyncMeasuresLatency() {
        var c = ClockSync()
        // Tablet clock is 5 s ahead; 2 ms round trip.
        c.update(macSent: 1_000_000, macReceived: 1_002_000, tabletTime: 6_001_000)
        #expect(c.offsetMicros == 5_000_000)
        #expect(c.latency(tabletMicros: 6_010_000, macNow: 1_013_500) == 3_500)
    }
}
