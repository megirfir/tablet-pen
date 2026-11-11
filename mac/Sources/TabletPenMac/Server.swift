import Foundation
import Network
import TabletPenCore

struct LinkStats {
    var connected = false
    var tabletName = ""
    var latencyMs = 0.0          // recent average, sample timestamp → event posted
    var latencyMaxMs = 0.0
    var samplesPerSec = 0
    var rttMs = 0.0
}

/// Accepts the tablet's TCP connection and runs the input pipeline. Everything here runs on
/// `queue` so no input ever waits for the main thread.
final class Server {
    let queue = DispatchQueue(label: "tabletpen.input", qos: .userInteractive)
    private var listener: NWListener?
    private var conn: NWConnection?
    private var reader = FrameReader()
    private let pipeline: InputPipeline
    let injector: Injector
    private var clock = ClockSync()
    private var timer: DispatchSourceTimer?
    private var pingSeq: UInt32 = 0
    private var pingSent: [UInt32: UInt64] = [:]
    private var tickCount = 0
    private var latSum: Int64 = 0, latCount: Int64 = 0, latMax: Int64 = 0, sampleCount = 0
    private var stats = LinkStats()
    private var recorder: FileHandle?
    var onStats: ((LinkStats) -> Void)?
    /// When false (no Accessibility permission yet) input is received and measured but not injected.
    var injectionEnabled = true

    init(settings: Settings) {
        pipeline = InputPipeline(settings: settings)
        injector = Injector(settings: settings)
    }

    func update(settings: Settings) {
        queue.async { self.pipeline.settings = settings; self.injector.settings = settings }
    }

    func setRecording(_ url: URL?) {
        queue.async {
            try? self.recorder?.close(); self.recorder = nil
            guard let url else { return }
            FileManager.default.createFile(atPath: url.path, contents: nil)
            self.recorder = try? FileHandle(forWritingTo: url)
            Log.info("recording input to \(url.path)")
        }
    }

    func start() {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        // USB only for now: adb reverse delivers the tablet's connection on loopback. Nothing on
        // the network can reach this port, so unauthenticated input injection is not exposed.
        params.requiredInterfaceType = .loopback
        do {
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Proto.port)!)
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.stateUpdateHandler = { s in Log.info("listener \(s)") }
            l.start(queue: queue)
            listener = l
        } catch {
            Log.info("listener failed: \(error)")
        }
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now(), repeating: .microseconds(8333), leeway: .microseconds(500))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func accept(_ c: NWConnection) {
        if let old = conn { old.cancel(); dropped() }
        conn = c
        reader = FrameReader()
        clock = ClockSync()
        pingSent.removeAll()
        c.stateUpdateHandler = { [weak self, weak c] s in
            guard let self, let c, c === self.conn else { return }
            switch s {
            case .ready:
                Log.info("tablet connected")
                self.stats.connected = true
                self.send(.hello(version: Proto.version, role: 1, width: 0, height: 0, refreshX10: 0, dpi: 0,
                                 name: Host.current().localizedName ?? "Mac"))
                self.receive(c)
            case .failed, .cancelled:
                self.conn = nil; self.dropped()
            default: break
            }
        }
        c.start(queue: queue)
    }

    private func dropped() {
        Log.info("tablet disconnected")
        for e in pipeline.reset() where injectionEnabled { injector.apply(e) }
        if injectionEnabled { injector.releaseAll() }
        stats = LinkStats()
        onStats?(stats)
    }

    private func receive(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak c] data, _, done, err in
            guard let self, let c, c === self.conn else { return }
            if let data, !data.isEmpty {
                self.recorder?.write(data)
                for r in self.reader.feed(data) {
                    if case let .success(m) = r { self.handle(m) }
                }
            }
            if done || err != nil { c.cancel(); return }
            self.receive(c)
        }
    }

    private func send(_ m: Message) {
        conn?.send(content: Data(Codec.encode(m)), completion: .contentProcessed { _ in })
    }

    private func handle(_ m: Message) {
        switch m {
        case let .hello(_, _, w, h, hz, dpi, name):
            Log.info("hello from '\(name)' surface \(w)x\(h) @\(Double(hz) / 10) Hz, \(dpi) dpi")
            stats.tabletName = name
            _ = pipeline.handle(m)
            injector.tabletAspect = pipeline.surface.aspect
        case let .ping(seq, t):
            send(.pong(seq: seq, echoedMicros: t, responderMicros: nowMicros()))
        case let .pong(seq, echoed, tablet):
            if pingSent.removeValue(forKey: seq) != nil {
                clock.update(macSent: echoed, macReceived: nowMicros(), tabletTime: tablet)
                stats.rttMs = Double(clock.rttMicros ?? 0) / 1000
            }
        case let .input(base, samples):
            let events = pipeline.handle(m)
            if injectionEnabled { for e in events { injector.apply(e) } }
            trace(events, base, samples)
            // Latency of the newest sample in the batch, measured after its events were posted.
            if let last = samples.last, let l = clock.latency(tabletMicros: base + UInt64(last.dtMicros), macNow: nowMicros()) {
                latSum += l; latCount += 1; latMax = max(latMax, l)
            }
            sampleCount += samples.count
        case .penButton:
            let events = pipeline.handle(m)
            if injectionEnabled { for e in events { injector.apply(e) } }
        default:
            break
        }
    }

    /// Logs every click decision with its timing, so mis-clicks can be diagnosed from the log.
    private func trace(_ events: [OutputEvent], _ base: UInt64, _ samples: [Sample]) {
        for e in events {
            if case let .button(b, down, clicks) = e, let s = samples.last {
                Log.info(String(format: "button %@ %@ clicks=%d tool=%@ t=%.3f", "\(b)", down ? "down" : "up", clicks,
                                "\(s.tool)", Double(base + UInt64(s.dtMicros)) / 1e6))
            }
        }
    }

    private func tick() {
        if injectionEnabled { for e in pipeline.tick(now: ProcessInfo.processInfo.systemUptime) { injector.apply(e) } }
        tickCount += 1
        guard conn != nil, stats.connected else { return }
        if tickCount % 30 == 0 {            // 4 Hz ping
            pingSeq &+= 1
            let t = nowMicros()
            pingSent[pingSeq] = t
            if pingSent.count > 16 { pingSent = pingSent.filter { $0.key &+ 16 > pingSeq } }
            send(.ping(seq: pingSeq, senderMicros: t))
        }
        if tickCount % 60 == 0 {            // 2 Hz stats
            if latCount > 0 {
                stats.latencyMs = Double(latSum) / Double(latCount) / 1000
                stats.latencyMaxMs = Double(latMax) / 1000
            }
            stats.samplesPerSec = sampleCount * 2
            if sampleCount > 0 {
                Log.info(String(format: "stats latency avg %.2f ms max %.2f ms, %d samples/s, rtt %.2f ms",
                                stats.latencyMs, stats.latencyMaxMs, stats.samplesPerSec, stats.rttMs))
            }
            latSum = 0; latCount = 0; latMax = 0; sampleCount = 0
            send(.stats(latencyMicros: UInt32(max(0, min(stats.latencyMs * 1000, 4e9))), eventsPerSec: UInt16(min(stats.samplesPerSec, 65535))))
            onStats?(stats)
        }
    }
}
