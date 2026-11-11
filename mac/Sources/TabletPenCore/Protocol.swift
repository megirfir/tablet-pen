import Foundation

/// Wire protocol v1 — see /protocol/SPEC.md.
public enum Proto {
    public static let port: UInt16 = 27183
    public static let version: UInt16 = 1
    public static let sampleSize = 17
}

public enum Tool: UInt8, Sendable { case finger = 0, pen = 1, eraser = 2, mouse = 3 }

public enum Action: UInt8, Sendable {
    case move = 0, down = 1, up = 2, hoverMove = 3, hoverEnter = 4, hoverExit = 5, cancel = 6
}

public struct SampleFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let buttonPrimary = SampleFlags(rawValue: 1)
    public static let buttonSecondary = SampleFlags(rawValue: 2)
    public static let contact = SampleFlags(rawValue: 4)
    public static let historical = SampleFlags(rawValue: 8)
}

public struct Sample: Equatable, Sendable {
    public var dtMicros: UInt32
    public var pointerId: UInt8
    public var tool: Tool
    public var action: Action
    public var flags: SampleFlags
    public var x: UInt16
    public var y: UInt16
    public var pressure: UInt16
    public var tiltX: Int8
    public var tiltY: Int8
    public var orientation: UInt16

    public init(dtMicros: UInt32, pointerId: UInt8, tool: Tool, action: Action, flags: SampleFlags,
                x: UInt16, y: UInt16, pressure: UInt16, tiltX: Int8, tiltY: Int8, orientation: UInt16) {
        self.dtMicros = dtMicros; self.pointerId = pointerId; self.tool = tool; self.action = action
        self.flags = flags; self.x = x; self.y = y; self.pressure = pressure
        self.tiltX = tiltX; self.tiltY = tiltY; self.orientation = orientation
    }

    public var nx: Double { Double(x) / 65535 }
    public var ny: Double { Double(y) / 65535 }
    public var np: Double { Double(pressure) / 65535 }
}

public enum Message: Equatable, Sendable {
    case hello(version: UInt16, role: UInt8, width: UInt16, height: UInt16, refreshX10: UInt16, dpi: UInt16, name: String)
    case input(baseMicros: UInt64, samples: [Sample])
    case ping(seq: UInt32, senderMicros: UInt64)
    case pong(seq: UInt32, echoedMicros: UInt64, responderMicros: UInt64)
    case mode(mode: UInt8, flags: UInt8)
    case key(keyCode: UInt16, modifiers: UInt8, action: UInt8)
    /// Pen side button (Bluetooth): 1 click, 2 double click, 3 long press.
    case penButton(kind: UInt8)
    /// Mac → tablet, for the debug overlay.
    case stats(latencyMicros: UInt32, eventsPerSec: UInt16)
    case unknown(type: UInt8, payload: [UInt8])
}

public enum ProtocolError: Error { case truncated, badMagic, badEnum }

struct Writer {
    var bytes: [UInt8] = []
    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func u16(_ v: UInt16) { bytes.append(UInt8(v & 0xFF)); bytes.append(UInt8(v >> 8)) }
    mutating func u32(_ v: UInt32) { for i in 0..<4 { bytes.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
    mutating func u64(_ v: UInt64) { for i in 0..<8 { bytes.append(UInt8((v >> (8 * UInt64(i))) & 0xFF)) } }
}

struct Reader {
    let bytes: ArraySlice<UInt8>
    var pos: Int
    init(_ b: ArraySlice<UInt8>) { bytes = b; pos = b.startIndex }
    var remaining: Int { bytes.endIndex - pos }
    mutating func u8() throws -> UInt8 {
        guard remaining >= 1 else { throw ProtocolError.truncated }
        defer { pos += 1 }; return bytes[pos]
    }
    mutating func u16() throws -> UInt16 { let a = try u8(), b = try u8(); return UInt16(a) | UInt16(b) << 8 }
    mutating func u32() throws -> UInt32 { let a = try u16(), b = try u16(); return UInt32(a) | UInt32(b) << 16 }
    mutating func u64() throws -> UInt64 { let a = try u32(), b = try u32(); return UInt64(a) | UInt64(b) << 32 }
    mutating func take(_ n: Int) throws -> [UInt8] {
        guard remaining >= n else { throw ProtocolError.truncated }
        defer { pos += n }; return Array(bytes[pos..<pos + n])
    }
}

public enum Codec {
    static let magic: [UInt8] = Array("TPEN".utf8)

    /// Full frame: length prefix + type + payload.
    public static func encode(_ m: Message) -> [UInt8] {
        var w = Writer()
        switch m {
        case let .hello(version, role, width, height, refresh, dpi, name):
            let n = Array(name.utf8.prefix(255))
            w.u8(0x01); w.bytes += magic; w.u16(version); w.u8(role)
            w.u16(width); w.u16(height); w.u16(refresh); w.u16(dpi); w.u8(UInt8(n.count)); w.bytes += n
        case let .input(base, samples):
            precondition((1...255).contains(samples.count), "1..255 samples per batch")
            w.u8(0x02); w.u64(base); w.u8(UInt8(samples.count))
            for s in samples {
                w.u32(s.dtMicros); w.u8(s.pointerId); w.u8(s.action.rawValue << 4 | s.tool.rawValue)
                w.u8(s.flags.rawValue); w.u16(s.x); w.u16(s.y); w.u16(s.pressure)
                w.u8(UInt8(bitPattern: s.tiltX)); w.u8(UInt8(bitPattern: s.tiltY)); w.u16(s.orientation)
            }
        case let .ping(seq, t): w.u8(0x03); w.u32(seq); w.u64(t)
        case let .pong(seq, e, r): w.u8(0x04); w.u32(seq); w.u64(e); w.u64(r)
        case let .mode(mode, flags): w.u8(0x05); w.u8(mode); w.u8(flags)
        case let .key(code, mods, action): w.u8(0x06); w.u16(code); w.u8(mods); w.u8(action)
        case let .penButton(kind): w.u8(0x07); w.u8(kind)
        case let .stats(lat, eps): w.u8(0x08); w.u32(lat); w.u16(eps)
        case let .unknown(type, payload): w.u8(type); w.bytes += payload
        }
        var out = Writer()
        out.u16(UInt16(w.bytes.count))
        return out.bytes + w.bytes
    }

    /// Decodes one frame body (type + payload, no length prefix).
    public static func decode(_ body: ArraySlice<UInt8>) throws -> Message {
        var r = Reader(body)
        let type = try r.u8()
        switch type {
        case 0x01:
            guard try r.take(4) == magic else { throw ProtocolError.badMagic }
            let v = try r.u16(), role = try r.u8(), w = try r.u16(), h = try r.u16(), hz = try r.u16(), dpi = try r.u16()
            let name = try r.take(Int(try r.u8()))
            return .hello(version: v, role: role, width: w, height: h, refreshX10: hz, dpi: dpi,
                          name: String(decoding: name, as: UTF8.self))
        case 0x02:
            let base = try r.u64()
            let count = Int(try r.u8())
            var samples: [Sample] = []
            samples.reserveCapacity(count)
            for _ in 0..<count {
                let dt = try r.u32(), pid = try r.u8(), ta = try r.u8(), fl = try r.u8()
                let x = try r.u16(), y = try r.u16(), p = try r.u16()
                let tx = Int8(bitPattern: try r.u8()), ty = Int8(bitPattern: try r.u8()), o = try r.u16()
                guard let tool = Tool(rawValue: ta & 0xF), let action = Action(rawValue: ta >> 4) else {
                    throw ProtocolError.badEnum
                }
                samples.append(Sample(dtMicros: dt, pointerId: pid, tool: tool, action: action,
                                      flags: SampleFlags(rawValue: fl), x: x, y: y, pressure: p,
                                      tiltX: tx, tiltY: ty, orientation: o))
            }
            return .input(baseMicros: base, samples: samples)
        case 0x03: return .ping(seq: try r.u32(), senderMicros: try r.u64())
        case 0x04: return .pong(seq: try r.u32(), echoedMicros: try r.u64(), responderMicros: try r.u64())
        case 0x05: return .mode(mode: try r.u8(), flags: try r.u8())
        case 0x06: return .key(keyCode: try r.u16(), modifiers: try r.u8(), action: try r.u8())
        case 0x07: return .penButton(kind: try r.u8())
        case 0x08: return .stats(latencyMicros: try r.u32(), eventsPerSec: try r.u16())
        default: return .unknown(type: type, payload: try r.take(r.remaining))
        }
    }
}

/// Incremental stream splitter: feed arbitrary chunks, get complete messages out.
public struct FrameReader {
    private var buf: [UInt8] = []
    public init() {}

    public mutating func feed<S: Sequence>(_ data: S) -> [Result<Message, Error>] where S.Element == UInt8 {
        buf.append(contentsOf: data)
        var out: [Result<Message, Error>] = []
        var pos = 0
        while buf.count - pos >= 2 {
            let n = Int(buf[pos]) | Int(buf[pos + 1]) << 8
            if n == 0 { pos += 2; continue }
            guard buf.count - pos - 2 >= n else { break }
            out.append(Result { try Codec.decode(buf[(pos + 2)..<(pos + 2 + n)]) })
            pos += 2 + n
        }
        if pos > 0 { buf.removeFirst(pos) }
        return out
    }
}
