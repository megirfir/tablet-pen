import Foundation
import TabletPenCore

/// Finds adb, watches for the tablet over USB and sets up `adb reverse` so the tablet can reach
/// the Mac's listener on 127.0.0.1.
final class AdbBridge {
    enum State: Equatable {
        case adbMissing
        case noDevice
        case unauthorized
        case ready(serial: String)

        var text: String {
            switch self {
            case .adbMissing: return "adb not found — install Android platform-tools"
            case .noDevice: return "USB: no tablet (check the cable is a data cable)"
            case .unauthorized: return "USB: tap “Allow USB debugging” on the tablet"
            case let .ready(serial): return "USB: tablet \(serial) tunnelled"
            }
        }
    }

    private let queue = DispatchQueue(label: "tabletpen.adb", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var state = State.noDevice
    private var reversed: Set<String> = []
    var onState: ((State) -> Void)?

    static func findAdb() -> String? {
        let home = NSHomeDirectory()
        var candidates = [
            "/opt/homebrew/share/android-commandlinetools/platform-tools/adb",
            "\(home)/Library/Android/sdk/platform-tools/adb",
            "/usr/local/share/android-commandlinetools/platform-tools/adb",
        ]
        for v in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let p = ProcessInfo.processInfo.environment[v] { candidates.insert("\(p)/platform-tools/adb", at: 0) }
        }
        candidates += ["/opt/homebrew/bin/adb", "/usr/local/bin/adb"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func run(_ adb: String, _ args: [String]) -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: adb)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 2.0)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    private func set(_ s: State) {
        guard s != state else { return }
        state = s
        Log.info("adb: \(s.text)")
        onState?(s)
    }

    private func poll() {
        guard let adb = Self.findAdb() else { set(.adbMissing); return }
        let (status, out) = run(adb, ["devices"])
        guard status == 0 else { set(.adbMissing); return }
        var ready: [String] = [], unauthorized = false
        for line in out.split(separator: "\n").dropFirst() {
            let f = line.split(separator: "\t")
            guard f.count >= 2 else { continue }
            if f[1] == "device" { ready.append(String(f[0])) }
            if f[1] == "unauthorized" { unauthorized = true }
        }
        reversed.formIntersection(ready)
        for serial in ready where !reversed.contains(serial) {
            let r = run(adb, ["-s", serial, "reverse", "tcp:\(Proto.port)", "tcp:\(Proto.port)"])
            if r.status == 0 { reversed.insert(serial) }
            Log.info("adb reverse on \(serial): \(r.status == 0 ? "ok" : "failed")")
        }
        if let s = ready.first(where: { reversed.contains($0) }) { set(.ready(serial: s)) }
        else if unauthorized { set(.unauthorized) }
        else { set(.noDevice) }
    }
}
