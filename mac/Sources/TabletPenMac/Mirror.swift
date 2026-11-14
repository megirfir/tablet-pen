import CoreMedia
import Foundation
import ScreenCaptureKit
import VideoToolbox

/// Captures one display with ScreenCaptureKit and encodes it as a low-delay H.264 stream for the
/// tablet's Mirror tab. Needs the Screen Recording permission. All state lives on `queue`.
final class ScreenMirror: NSObject, SCStreamOutput, SCStreamDelegate {
    private let queue = DispatchQueue(label: "tabletpen.mirror", qos: .userInteractive)
    private var stream: SCStream?
    private var session: VTCompressionSession?
    private var sessionSize = (0, 0)
    private var generation = 0
    private var running: (display: CGDirectDisplayID, maxW: Int, maxH: Int)?
    private var forceKey = true
    private var forceConfig = true
    private var sentParams: [[UInt8]] = []
    private var lastBuffer: CVPixelBuffer?
    private var lastFrameAt = 0.0
    private var refineLeft = 0
    private var lastPts: Int64 = 0
    private var timer: DispatchSourceTimer?

    /// Stream parameters: coded width/height, SPS, PPS. Called on the mirror queue.
    var onConfig: ((Int, Int, [UInt8], [UInt8]) -> Void)?
    /// One Annex-B access unit and whether it is a keyframe. Called on the mirror queue.
    var onFrame: ((Data, Bool) -> Void)?
    var onError: ((String) -> Void)?

    /// Starts mirroring `display`, scaled to fit maxWidth × maxHeight. If that is already running,
    /// re-sends the parameters and a keyframe instead (the tablet's decoder restarted).
    func start(display: CGDirectDisplayID, maxWidth: Int, maxHeight: Int) {
        queue.async {
            if let r = self.running, r.display == display, r.maxW == maxWidth, r.maxH == maxHeight {
                self.keyframeNow(resendConfig: true)
                return
            }
            self.teardown()
            self.running = (display, maxWidth, maxHeight)
            let gen = self.generation
            if CommandLine.arguments.contains("--mirror-pattern") { self.beginPattern(display, maxWidth, maxHeight); return }
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
                self.queue.async {
                    guard gen == self.generation else { return }
                    guard let content, let d = content.displays.first(where: { $0.displayID == display }) ?? content.displays.first else {
                        self.fail("screen capture unavailable: \(error?.localizedDescription ?? "no display") — allow TabletPen under System Settings → Privacy & Security → Screen Recording")
                        return
                    }
                    self.begin(d, maxWidth, maxHeight, gen)
                }
            }
        }
    }

    func stop() { queue.async { self.teardown() } }

    /// Asks for a keyframe (the receiver lost frames).
    func requestKeyframe() { queue.async { self.keyframeNow(resendConfig: false) } }

    private var lastFailure = (text: "", at: 0.0)

    private func fail(_ text: String) {
        // The tablet keeps asking while it has no picture; don't fill the log with the same line.
        let now = ProcessInfo.processInfo.systemUptime
        if text != lastFailure.text || now - lastFailure.at > 60 { Log.info("mirror: \(text)"); lastFailure = (text, now) }
        teardown()
        onError?(text)
    }

    private func teardown() {
        generation += 1
        running = nil
        timer?.cancel(); timer = nil
        if let s = stream { s.stopCapture { _ in } }
        stream = nil
        if let s = session { VTCompressionSessionInvalidate(s) }
        session = nil
        lastBuffer = nil; refineLeft = 0; sentParams = []
        forceKey = true; forceConfig = true
    }

    /// Native pixel size of the display, scaled down (never up) to fit the tablet's view.
    private func outputSize(_ display: CGDirectDisplayID, _ maxW: Int, _ maxH: Int) -> (Int, Int) {
        let b = CGDisplayBounds(display)
        var pw = Int(b.width) * 2, ph = Int(b.height) * 2
        if let mode = CGDisplayCopyDisplayMode(display) { pw = mode.pixelWidth; ph = mode.pixelHeight }
        let k = min(1, Double(maxW) / Double(max(pw, 1)), Double(maxH) / Double(max(ph, 1)))
        return (max(Int(Double(pw) * k) & ~1, 64), max(Int(Double(ph) * k) & ~1, 64))
    }

    /// Diagnostic (`TabletPen --mirror-pattern`): streams a generated test picture instead of the
    /// screen, to check encoder → link → tablet decoder without the Screen Recording permission.
    private func beginPattern(_ display: CGDirectDisplayID, _ maxW: Int, _ maxH: Int) {
        let (w, h) = outputSize(display, maxW, maxH)
        Log.info("mirror: test pattern at \(w)x\(h)")
        var frame = 0
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0 / 30)
        t.setEventHandler { [weak self] in
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
            guard let self, let pb else { return }
            CVPixelBufferLockBaseAddress(pb, [])
            let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
            let ys = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            let c = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!
            memset(c, 128, CVPixelBufferGetBytesPerRowOfPlane(pb, 1) * (h / 2))
            let bar = (frame * 12) % w
            for row in 0..<h {
                let line = y + row * ys
                // Checkerboard of 1/8-size squares, a border, and a moving vertical bar.
                for x in 0..<w {
                    let edge = row < 6 || row >= h - 6 || x < 6 || x >= w - 6
                    let check = ((x * 8 / w) + (row * 8 / h)) % 2 == 0
                    line[x] = edge ? 235 : (abs(x - bar) < 10 ? 16 : (check ? 200 : 90))
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            frame += 1
            self.lastBuffer = pb
            self.encode(pb)
        }
        t.resume()
        timer = t
    }

    private func begin(_ d: SCDisplay, _ maxW: Int, _ maxH: Int, _ gen: Int) {
        let (w, h) = outputSize(d.displayID, maxW, maxH)

        let cfg = SCStreamConfiguration()
        cfg.width = w; cfg.height = h
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        cfg.queueDepth = 5
        cfg.showsCursor = true
        let s = SCStream(filter: SCContentFilter(display: d, excludingWindows: []), configuration: cfg, delegate: self)
        do { try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue) } catch {
            fail("could not attach to the screen stream: \(error.localizedDescription)"); return
        }
        stream = s
        s.startCapture { error in
            guard let error else { return }
            self.queue.async { if gen == self.generation { self.fail("screen capture did not start: \(error.localizedDescription)") } }
        }
        Log.info("mirror: capturing display \(d.displayID) at \(w)x\(h)")

        // The screen stream only delivers frames when something changes. After the last change,
        // encode that frame a couple more times so the picture sharpens to full quality.
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.1, repeating: 0.1)
        t.setEventHandler { [weak self] in
            guard let self, let b = self.lastBuffer, self.refineLeft > 0,
                  ProcessInfo.processInfo.systemUptime - self.lastFrameAt > 0.09 else { return }
            self.refineLeft -= 1
            self.encode(b)
        }
        t.resume()
        timer = t
    }

    private func keyframeNow(resendConfig: Bool) {
        forceKey = true
        if resendConfig { forceConfig = true }
        if let b = lastBuffer { encode(b) }       // the screen may be idle, so don't wait for a new frame
    }

    // MARK: SCStream

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, stream === self.stream,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        lastBuffer = pb
        lastFrameAt = ProcessInfo.processInfo.systemUptime
        refineLeft = 2
        encode(pb)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { if stream === self.stream { self.fail("screen capture stopped: \(error.localizedDescription)") } }
    }

    // MARK: Encoder

    private func makeSession(_ w: Int, _ h: Int) -> VTCompressionSession? {
        var s: VTCompressionSession?
        let st = VTCompressionSessionCreate(allocator: nil, width: Int32(w), height: Int32(h), codecType: kCMVideoCodecType_H264,
                                            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                            outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard st == noErr, let s else { Log.info("mirror: encoder create failed (\(st))"); return nil }
        func set(_ k: CFString, _ v: CFTypeRef) { VTSessionSetProperty(s, key: k, value: v) }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)       // no B-frames: no added delay
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
        set(kVTCompressionPropertyKey_AverageBitRate, 20_000_000 as CFNumber)      // USB: bandwidth is not the limit, text sharpness is
        set(kVTCompressionPropertyKey_ExpectedFrameRate, 60 as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, 3600 as CFNumber)       // keyframes on request, not on a schedule
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 60 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(s)
        return s
    }

    private func encode(_ pb: CVPixelBuffer) {
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        if session == nil || sessionSize != (w, h) {
            if let s = session { VTCompressionSessionInvalidate(s) }
            session = makeSession(w, h); sessionSize = (w, h)
            forceKey = true; forceConfig = true
        }
        guard let session else { return }
        let pts = max(Int64(nowMicros()), lastPts + 1)
        lastPts = pts
        let props: CFDictionary? = forceKey ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        forceKey = false
        let gen = generation
        let st = VTCompressionSessionEncodeFrame(session, imageBuffer: pb, presentationTimeStamp: CMTime(value: pts, timescale: 1_000_000),
                                                 duration: .invalid, frameProperties: props, infoFlagsOut: nil) { [weak self] status, _, sb in
            guard status == noErr, let sb, let self else { return }
            self.queue.async { if gen == self.generation { self.emit(sb) } }
        }
        if st != noErr { Log.info("mirror: encode failed (\(st))"); forceKey = true }
    }

    private func emit(_ sb: CMSampleBuffer) {
        guard let bb = CMSampleBufferGetDataBuffer(sb), let fmt = CMSampleBufferGetFormatDescription(sb) else { return }
        let att = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]])?.first
        let key = !((att?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
        let start: [UInt8] = [0, 0, 0, 1]
        var out = Data()

        if key {
            var params: [[UInt8]] = []
            var count = 0, nalLen: Int32 = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalLen)
            for i in 0..<count {
                var p: UnsafePointer<UInt8>?
                var n = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: i, parameterSetPointerOut: &p, parameterSetSizeOut: &n,
                                                                      parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let p {
                    params.append(Array(UnsafeBufferPointer(start: p, count: n)))
                }
            }
            guard params.count >= 2, nalLen == 4 else { Log.info("mirror: unexpected stream format"); return }
            if forceConfig || params != sentParams {
                let d = CMVideoFormatDescriptionGetDimensions(fmt)
                onConfig?(Int(d.width), Int(d.height), params[0], params[1])
                sentParams = params; forceConfig = false
            }
            for p in params { out.append(contentsOf: start); out.append(contentsOf: p) }
        }

        // AVCC (4-byte big-endian length before each NAL unit) → Annex B (start codes).
        let total = CMBlockBufferGetDataLength(bb)
        let head = out.count
        out.count = head + total
        let ok = out.withUnsafeMutableBytes { raw -> Bool in
            let base = raw.baseAddress!.advanced(by: head)
            guard CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: total, destination: base) == kCMBlockBufferNoErr else { return false }
            let b = base.assumingMemoryBound(to: UInt8.self)
            var i = 0
            while i + 4 <= total {
                let n = Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
                b[i] = 0; b[i + 1] = 0; b[i + 2] = 0; b[i + 3] = 1
                i += 4 + n
            }
            return i == total
        }
        guard ok else { Log.info("mirror: malformed encoder output"); forceKey = true; return }
        onFrame?(out, key)
    }
}
