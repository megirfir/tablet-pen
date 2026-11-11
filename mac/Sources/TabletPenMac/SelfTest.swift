import AppKit
import TabletPenCore

/// `TabletPen --selftest`: posts events through the real Injector at a window of our own and
/// checks that macOS delivers them. Verifies CGEvent injection end to end (needs Accessibility).
final class SelfTest: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var seen: [String: Int] = [:]
    var magnification = 0.0
    var scrollY = 0.0
    var phases: Set<UInt> = []
    var momentum: Set<UInt> = []
    var clickCounts: [Int] = []
    var lastLocation = NSPoint.zero

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard Injector.isTrusted else {
            print("SELFTEST FAIL: Accessibility permission not granted"); exit(2)
        }
        let screen = NSScreen.main!.frame
        window = NSWindow(contentRect: NSRect(x: screen.midX - 300, y: screen.midY - 200, width: 600, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "TabletPen self-test"
        window.acceptsMouseMovedEvents = true
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                                    .rightMouseDown, .rightMouseUp, .scrollWheel, .magnify]) { [unowned self] e in
            self.seen["\(e.type.rawValue)", default: 0] += 1
            switch e.type {
            case .scrollWheel:
                self.scrollY += e.scrollingDeltaY
                self.phases.insert(e.phase.rawValue); self.momentum.insert(e.momentumPhase.rawValue)
            case .magnify: self.magnification += e.magnification; self.phases.insert(e.phase.rawValue)
            case .leftMouseDown: self.clickCounts.append(e.clickCount)
            case .mouseMoved, .leftMouseDragged: self.lastLocation = NSEvent.mouseLocation
            default: break
            }
            return e
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.run() }
    }

    func run() {
        let inj = Injector(settings: Settings())
        let main = CGDisplayBounds(CGMainDisplayID())
        let start = CGEvent(source: nil)!.location
        var steps: [(Double, () -> Void)] = []
        func at(_ delay: Double, _ f: @escaping () -> Void) { steps.append((delay, f)) }
        // Absolute move to the middle of the main display (= middle of the window), stretch mapping.
        var s = Settings(); s.aspectFit = .stretch; inj.settings = s
        at(0.05) { inj.apply(.moveTo(nx: 0.5, ny: 0.5)) }
        for _ in 0..<20 { at(0.005) { inj.apply(.moveBy(dx: 3, dy: 2)) } }
        at(0.1) { inj.apply(.button(.left, down: true, clicks: 1)); inj.apply(.button(.left, down: false, clicks: 1)) }
        at(0.1) { inj.apply(.button(.left, down: true, clicks: 2)); inj.apply(.button(.left, down: false, clicks: 2)) }
        at(0.1) { inj.apply(.button(.left, down: true, clicks: 1)) }
        for _ in 0..<10 { at(0.005) { inj.apply(.moveBy(dx: 2, dy: 0)) } }
        at(0.02) { inj.apply(.button(.left, down: false, clicks: 1)) }
        at(0.1) { inj.apply(.button(.right, down: true, clicks: 1)); inj.apply(.button(.right, down: false, clicks: 1)) }
        at(0.1) {
            inj.apply(.scroll(dx: 0, dy: 0, phase: .began, momentum: .none))
            for _ in 0..<10 { inj.apply(.scroll(dx: 0, dy: 12, phase: .changed, momentum: .none)) }
            inj.apply(.scroll(dx: 0, dy: 0, phase: .ended, momentum: .none))
            inj.apply(.scroll(dx: 0, dy: 8, phase: .none, momentum: .begin))
            inj.apply(.scroll(dx: 0, dy: 4, phase: .none, momentum: .continuing))
            inj.apply(.scroll(dx: 0, dy: 0, phase: .none, momentum: .end))
        }
        at(0.2) {
            inj.apply(.magnify(delta: 0, phase: .began))
            for _ in 0..<10 { inj.apply(.magnify(delta: 0.05, phase: .changed)) }
            inj.apply(.magnify(delta: 0, phase: .ended))
        }
        at(0.5) {
            let loc = NSEvent.mouseLocation
            let expect = NSPoint(x: main.midX + 60 + 20, y: NSScreen.screens[0].frame.height - (main.midY + 40))
            var ok = true
            func check(_ name: String, _ pass: Bool, _ detail: String) {
                print("\(pass ? "PASS" : "FAIL")  \(name): \(detail)"); if !pass { ok = false }
            }
            check("cursor position", abs(loc.x - expect.x) < 3 && abs(loc.y - expect.y) < 3, "at \(loc), expected ≈ \(expect)")
            check("mouse moved", self.seen["\(NSEvent.EventType.mouseMoved.rawValue)", default: 0] >= 10, "\(self.seen["5", default: 0]) events")
            check("left click + double click", self.clickCounts == [1, 2, 1], "clickCounts \(self.clickCounts)")
            check("drag", self.seen["\(NSEvent.EventType.leftMouseDragged.rawValue)", default: 0] >= 5, "\(self.seen["6", default: 0]) events")
            check("right click", self.seen["\(NSEvent.EventType.rightMouseDown.rawValue)", default: 0] == 1, "\(self.seen["3", default: 0])")
            check("scroll deltas", abs(self.scrollY - 132) < 2, "sum \(self.scrollY) (expected 132)")
            check("scroll phases", self.phases.isSuperset(of: [1, 4, 8]) , "phases \(self.phases.sorted()) momentum \(self.momentum.sorted())")
            check("momentum phases", self.momentum.count >= 3, "\(self.momentum.sorted())")
            check("pinch zoom (private gesture event)", abs(self.magnification - 0.5) < 0.01, "sum \(self.magnification) (expected 0.5)")
            CGWarpMouseCursorPosition(start)
            print(ok ? "SELFTEST PASS" : "SELFTEST FAIL")
            exit(ok ? 0 : 1)
        }
        var t = 0.0
        for (d, f) in steps { t += d; DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
    }
}
