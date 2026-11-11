import Foundation
import TabletPenCore

/// Monotonic Mac clock in microseconds.
func nowMicros() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000 }

enum Log {
    static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("TabletPen.log")
    }()
    private static let queue = DispatchQueue(label: "log")
    private static let handle: FileHandle? = {
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let h = try? FileHandle(forWritingTo: url)
        _ = try? h?.seekToEnd()
        return h
    }()
    private static let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss.SSS"; return f }()

    static func info(_ s: String) {
        let line = "\(fmt.string(from: Date())) \(s)\n"
        queue.async {
            handle?.write(line.data(using: .utf8)!)
            FileHandle.standardError.write(line.data(using: .utf8)!)
        }
    }
}

enum SettingsStore {
    static let key = "settings.v1"
    static func load() -> Settings {
        guard let d = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(Settings.self, from: d) else { return Settings() }
        return s
    }
    static func save(_ s: Settings) {
        if let d = try? JSONEncoder().encode(s) { UserDefaults.standard.set(d, forKey: key) }
    }
}
