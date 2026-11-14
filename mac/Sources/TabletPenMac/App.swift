import AppKit
import SwiftUI
import TabletPenCore

final class AppModel: ObservableObject {
    @Published var settings = SettingsStore.load() { didSet { if settings != oldValue { SettingsStore.save(settings); onChange?(settings) } } }
    @Published var stats = LinkStats()
    @Published var usb = AdbBridge.State.noDevice
    @Published var trusted = Injector.isTrusted
    var onChange: ((TabletPenCore.Settings) -> Void)?
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let model = AppModel()
    var server: Server!
    let adb = AdbBridge()
    var item: NSStatusItem!
    var hud: HUD?
    var settingsWindow: NSWindow?
    var trustTimer: Timer?
    var recording = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("TabletPen starting, accessibility trusted=\(model.trusted)")
        server = Server(settings: model.settings)
        server.injectionEnabled = model.trusted
        server.onStats = { [weak self] s in DispatchQueue.main.async { self?.model.stats = s; self?.refresh() } }
        server.start()
        adb.onState = { [weak self] s in DispatchQueue.main.async { self?.model.usb = s; self?.refresh() } }
        adb.start()
        model.onChange = { [weak self] s in self?.server.update(settings: s); self?.refresh() }

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        refresh()

        if !model.trusted { Injector.promptForAccessibility() }
        // Pick up the Accessibility grant without a restart.
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let t = Injector.isTrusted
            if t != self.model.trusted {
                self.model.trusted = t
                self.server.queue.async { self.server.injectionEnabled = t }
                Log.info("accessibility trusted=\(t)")
                self.refresh()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        server.queue.sync { server.injector.releaseAll() }
    }

    func refresh() {
        let connected = model.stats.connected
        item.button?.image = NSImage(systemSymbolName: connected ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle",
                                     accessibilityDescription: "TabletPen")
        if model.settings.showHUD {
            if hud == nil { hud = HUD() }
            hud?.update(model.stats)
        } else {
            hud?.close(); hud = nil
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = model.stats
        func info(_ t: String) { let i = NSMenuItem(title: t, action: nil, keyEquivalent: ""); i.isEnabled = false; menu.addItem(i) }
        func toggle(_ t: String, _ on: Bool, _ sel: Selector) {
            let i = NSMenuItem(title: t, action: sel, keyEquivalent: ""); i.target = self; i.state = on ? .on : .off; menu.addItem(i)
        }
        info(s.connected ? "Connected: \(s.tabletName)" : "Tablet app not connected")
        info(model.usb.text)
        if s.connected {
            info(String(format: "Latency %.1f ms (max %.1f) · %d samples/s", s.latencyMs, s.latencyMaxMs, s.samplesPerSec))
        }
        if s.mirroring { info("Mirroring this Mac's screen to the tablet") }
        if !s.mirrorError.isEmpty {
            menu.addItem(.separator())
            let i = NSMenuItem(title: "⚠︎ Mirror: allow Screen Recording…", action: #selector(openScreenRecording), keyEquivalent: "")
            i.target = self; menu.addItem(i)
        }
        if !model.trusted {
            menu.addItem(.separator())
            let i = NSMenuItem(title: "⚠︎ Grant Accessibility permission…", action: #selector(openAccessibility), keyEquivalent: "")
            i.target = self; menu.addItem(i)
        }
        menu.addItem(.separator())
        toggle("Fingers: absolute (touchscreen-style)", model.settings.fingerMode == .absolute, #selector(toggleFinger))
        toggle("Pen: absolute (maps to screen)", model.settings.penMode == .absolute, #selector(togglePen))
        toggle("Show latency overlay", model.settings.showHUD, #selector(toggleHUD))
        toggle("Record input session", recording, #selector(toggleRecording))
        menu.addItem(.separator())
        let st = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","); st.target = self; menu.addItem(st)
        menu.addItem(withTitle: "Quit TabletPen", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc func toggleFinger() { model.settings.fingerMode = model.settings.fingerMode == .absolute ? .relative : .absolute }
    @objc func togglePen() { model.settings.penMode = model.settings.penMode == .absolute ? .relative : .absolute }
    @objc func toggleHUD() { model.settings.showHUD.toggle() }

    @objc func toggleRecording() {
        recording.toggle()
        guard recording else { server.setRecording(nil); return }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TabletPen/recordings")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        server.setRecording(dir.appendingPathComponent("session-\(f.string(from: Date())).tpen"))
    }

    @objc func openAccessibility() {
        Injector.promptForAccessibility()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc func openScreenRecording() {
        CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "TabletPen Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(model: model))
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

/// Small click-through overlay with latency and event rate.
final class HUD {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 330, height: 26),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.7)
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.frame = NSRect(x: 8, y: 4, width: 314, height: 18)
        panel.contentView?.addSubview(label)
        if let f = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: f.maxX - 340, y: f.maxY - 34))
        }
        panel.orderFrontRegardless()
    }

    func update(_ s: LinkStats) {
        label.stringValue = s.connected
            ? String(format: "TabletPen  %.1f ms (max %.1f)  %d/s  rtt %.1f", s.latencyMs, s.latencyMaxMs, s.samplesPerSec, s.rttMs)
            : "TabletPen  not connected"
    }

    func close() { panel.close() }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Pointing") {
                Picker("Fingers", selection: $model.settings.fingerMode) {
                    Text("Relative (trackpad)").tag(PointingMode.relative)
                    Text("Absolute").tag(PointingMode.absolute)
                }
                Picker("Pen", selection: $model.settings.penMode) {
                    Text("Relative").tag(PointingMode.relative)
                    Text("Absolute (maps to screen)").tag(PointingMode.absolute)
                }
                slider("Sensitivity", $model.settings.sensitivity, 0.2...3)
                slider("Acceleration", $model.settings.acceleration, 0...2)
            }
            Section("Absolute mapping and Mirror") {
                Picker("Screen", selection: $model.settings.targetDisplay) {
                    Text("Main display").tag(UInt32(0))
                    ForEach(NSScreen.screens, id: \.self) { s in
                        let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
                        Text("\(s.localizedName) (\(Int(s.frame.width))×\(Int(s.frame.height)))").tag(id)
                    }
                }
                Picker("Aspect ratio", selection: $model.settings.aspectFit) {
                    Text("Letterbox (whole screen, part of tablet unused)").tag(AspectFit.letterbox)
                    Text("Crop (whole tablet, part of screen unreachable)").tag(AspectFit.crop)
                    Text("Stretch").tag(AspectFit.stretch)
                }
            }
            Section("Gestures") {
                Toggle("Tap to click", isOn: $model.settings.tapToClick)
                Toggle("Tap-and-drag (double-tap, hold, drag)", isOn: $model.settings.tapAndDrag)
                Toggle("Three-finger drag", isOn: $model.settings.threeFingerDrag)
                Toggle("Pinch to zoom", isOn: $model.settings.pinchZoom)
                Toggle("Natural scrolling", isOn: $model.settings.naturalScroll)
                Toggle("Momentum scrolling", isOn: $model.settings.momentumScroll)
                slider("Scroll speed", $model.settings.scrollSpeed, 0.2...3)
            }
            Section("Debug") {
                Toggle("Show latency overlay", isOn: $model.settings.showHUD)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 560)
    }

    func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).frame(width: 100, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: "%.2f", value.wrappedValue)).monospacedDigit().frame(width: 40)
        }
    }
}
