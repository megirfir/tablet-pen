import Foundation
import Testing
@testable import TabletPenCore

func hex(_ s: String) -> [UInt8] {
    var out: [UInt8] = []
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        out.append(UInt8(s[i..<j], radix: 16)!)
        i = j
    }
    return out
}

func vectors() throws -> [String: [UInt8]] {
    // Tests/TabletPenCoreTests/ProtocolTests.swift -> repo root /protocol/vectors/frames.txt
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("protocol/vectors/frames.txt")
    var out: [String: [UInt8]] = [:]
    for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") where !line.hasPrefix("#") {
        let parts = line.split(separator: ":")
        out[parts[0].trimmingCharacters(in: .whitespaces)] = hex(parts[1].trimmingCharacters(in: .whitespaces))
    }
    return out
}

func decodeFrame(_ f: [UInt8]) throws -> Message {
    var r = FrameReader()
    return try r.feed(f)[0].get()
}

@Test func vectorsRoundTrip() throws {
    let v = try vectors()
    #expect(v.count == 7)
    for (name, bytes) in v {
        #expect(Codec.encode(try decodeFrame(bytes)) == bytes, "vector \(name)")
    }
}

@Test func inputVectorFields() throws {
    let m = try decodeFrame(try vectors()["input"]!)
    #expect(m == .input(baseMicros: 123_456_789, samples: [
        Sample(dtMicros: 0, pointerId: 0, tool: .pen, action: .hoverMove, flags: .historical,
               x: 32768, y: 16384, pressure: 0, tiltX: -10, tiltY: 5, orientation: 49152),
        Sample(dtMicros: 4167, pointerId: 0, tool: .pen, action: .down, flags: [.contact, .buttonPrimary],
               x: 65535, y: 0, pressure: 40000, tiltX: 45, tiltY: -90, orientation: 0),
    ]))
}

@Test func helloVectorFields() throws {
    #expect(try decodeFrame(try vectors()["hello"]!) ==
        .hello(version: 1, role: 0, width: 2944, height: 1840, refreshX10: 1440, dpi: 273, name: "Tab"))
}

@Test func streamSplitAcrossChunks() throws {
    let v = try vectors()
    let all = ["ping", "mode", "key", "hello", "input", "penbutton", "stats"].flatMap { v[$0]! }
    for chunk in [1, 2, 3, 7, 64] {
        var r = FrameReader()
        var n = 0
        var i = 0
        while i < all.count {
            let c = min(chunk, all.count - i)
            n += r.feed(all[i..<i + c]).count
            i += c
        }
        #expect(n == 7, "chunk \(chunk)")
    }
}

@Test func unknownTypeIsSkipped() throws {
    var r = FrameReader()
    let got = r.feed(hex("0300ee0102") + hex("0300050100"))
    #expect(try got[0].get() == .unknown(type: 0xee, payload: [1, 2]))
    #expect(try got[1].get() == .mode(mode: 1, flags: 0))
}

@Test func truncatedBodyIsAnErrorNotACrash() {
    var r = FrameReader()
    let got = r.feed(hex("020003ff"))  // PING with a 1-byte payload
    #expect(throws: ProtocolError.self) { try got[0].get() }
}
