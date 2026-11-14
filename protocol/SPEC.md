# TabletPen wire protocol (v1)

One TCP stream between tablet (client) and Mac (server, port **27183**).
Over USB the tablet connects to `127.0.0.1:27183`, which `adb reverse tcp:27183 tcp:27183`
tunnels to the Mac. All integers are **little-endian**.

## Framing

```
u16 length   // bytes that follow (type + payload), 1..65535
u8  type
...payload
```

## Message types

| type | name   | direction | payload |
|------|--------|-----------|---------|
| 0x01 | HELLO  | both      | `"TPEN"` magic, u16 version, u8 role (0 tablet, 1 mac), u16 widthPx, u16 heightPx, u16 refreshHz×10, u16 dpi, u8 nameLen, name UTF-8. width/height are the capture surface in pixels; the tablet re-sends HELLO when it changes |
| 0x02 | INPUT  | tablet→mac | input batch, below |
| 0x03 | PING   | both      | u32 seq, u64 senderMicros |
| 0x04 | PONG   | both      | u32 seq, u64 echoedSenderMicros, u64 responderMicros |
| 0x05 | MODE   | both      | u8 mode (0 trackpad, 1 notes, 2 drawing, 3 annotate), u8 flags |
| 0x06 | KEY    | tablet→mac | u16 macVirtualKeyCode, u8 modifiers (1 cmd, 2 shift, 4 opt, 8 ctrl), u8 action (0 tap, 1 down, 2 up) |
| 0x07 | PENBTN | tablet→mac | u8 kind (1 click, 2 double click, 3 long press) — the pen's Bluetooth side button |
| 0x08 | STATS  | mac→tablet | u32 latencyMicros (recent average), u16 eventsPerSec — for the debug overlay |
| 0x10 | MIRROR | tablet→mac | u8 on (1 start, 0 stop), u16 maxWidthPx, u16 maxHeightPx — mirror the Mac screen, scaled to fit. Sent again while running = "send the parameters and a keyframe again" |
| 0x11 | VIDEOCFG | mac→tablet | u16 width, u16 height, u16 spsLen, SPS, u16 ppsLen, PPS — H.264 parameters (no start codes) |
| 0x12 | VIDEO | mac→tablet | u8 flags (bit0 first piece, bit1 last piece, bit2 keyframe), then up to 60000 bytes of one Annex-B access unit |
| 0x13–0x3F | reserved |

Unknown types must be skipped using the frame length, so newer peers stay compatible.

## INPUT batch

```
u64 baseMicros     // tablet monotonic clock (MotionEvent event time), microseconds
u8  count          // 1..255 samples
count × sample (17 bytes each)
```

Sample:

| field       | type | meaning |
|-------------|------|---------|
| dtMicros    | u32  | sample time = baseMicros + dtMicros |
| pointerId   | u8   | Android pointer id (multitouch) |
| toolAction  | u8   | low nibble tool: 0 finger, 1 pen, 2 eraser, 3 mouse. High nibble action: 0 move, 1 down, 2 up, 3 hover-move, 4 hover-enter, 5 hover-exit, 6 cancel |
| flags       | u8   | bit0 stylus primary button, bit1 stylus secondary button, bit2 in contact, bit3 historical (coalesced) sample |
| x           | u16  | 0..65535 = 0..1 across the capture surface, left→right |
| y           | u16  | 0..65535 = 0..1, top→bottom |
| pressure    | u16  | 0..65535 = 0..1 (clamped; raw, before any curve) |
| tiltX       | i8   | degrees, −90..90, positive = pen leans right |
| tiltY       | i8   | degrees, −90..90, positive = pen leans toward the user |
| orientation | u16  | 0..65535 = −π..π (Android AXIS_ORIENTATION) |

Every historical sample of a MotionEvent is sent (flag bit3) followed by the current one, in
time order, for every pointer, so nothing is dropped and the Mac can resample. One MotionEvent
normally becomes one batch; a batch never waits for more input (no added latency).

Curves (pressure, tilt dead zone, acceleration) are applied on the Mac so they can be changed
without touching the tablet.

## Mirroring

After MIRROR(on) the Mac captures one display, encodes H.264 (High profile, no B-frames) and sends
VIDEOCFG followed by access units, each split into VIDEO pieces because a frame's length field is
16 bits. Keyframes carry SPS/PPS in-band as well and are only sent at the start and on request; the
tablet asks for one (MIRROR(on) again) whenever its decoder restarts or it had to skip frames.

While mirroring, HELLO's width/height describe the picture area on the tablet and INPUT x/y are
normalized to that area, so 0..1 is exactly the mirrored display. The Mac treats all pointing as
absolute on that display: pen as usual, fingers "direct" (a tap clicks where it lands).
The stream ends with MIRROR(off) or when the connection drops.

## Latency measurement

PING/PONG gives round-trip time and a clock offset (`offset = responder − (sent + rtt/2)`).
The Mac then reports per-sample latency as `macNow − (sampleMicros + offset)`, which covers
tablet dispatch → socket → Mac receive → event post.

## Test vectors

`vectors/*.hex` hold frames as hex; both the Kotlin and Swift test suites decode and re-encode
them and must produce identical bytes.
