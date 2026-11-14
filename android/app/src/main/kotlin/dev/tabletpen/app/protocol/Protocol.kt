package dev.tabletpen.app.protocol

import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Wire protocol v1 — see /protocol/SPEC.md. Pure Kotlin/JVM so it is unit-testable off-device. */
object Proto {
    const val PORT = 27183
    const val VERSION = 1

    const val T_HELLO = 0x01
    const val T_INPUT = 0x02
    const val T_PING = 0x03
    const val T_PONG = 0x04
    const val T_MODE = 0x05
    const val T_KEY = 0x06
    const val T_PENBTN = 0x07
    const val T_STATS = 0x08
    const val T_MIRROR = 0x10
    const val T_VIDEOCFG = 0x11
    const val T_VIDEO = 0x12

    const val VIDEO_FIRST = 1
    const val VIDEO_LAST = 2
    const val VIDEO_KEY = 4

    const val TOOL_FINGER = 0
    const val TOOL_PEN = 1
    const val TOOL_ERASER = 2
    const val TOOL_MOUSE = 3

    const val ACT_MOVE = 0
    const val ACT_DOWN = 1
    const val ACT_UP = 2
    const val ACT_HOVER_MOVE = 3
    const val ACT_HOVER_ENTER = 4
    const val ACT_HOVER_EXIT = 5
    const val ACT_CANCEL = 6

    const val FLAG_BTN_PRIMARY = 1
    const val FLAG_BTN_SECONDARY = 2
    const val FLAG_CONTACT = 4
    const val FLAG_HISTORICAL = 8

    const val SAMPLE_SIZE = 17
}

data class Sample(
    val dtMicros: Long,
    val pointerId: Int,
    val tool: Int,
    val action: Int,
    val flags: Int,
    val x: Int,           // 0..65535
    val y: Int,           // 0..65535
    val pressure: Int,    // 0..65535
    val tiltX: Int,       // degrees -90..90
    val tiltY: Int,
    val orientation: Int, // 0..65535 = -pi..pi
)

sealed class Message {
    data class Hello(val version: Int, val role: Int, val width: Int, val height: Int, val refreshX10: Int, val dpi: Int, val name: String) : Message()
    data class Input(val baseMicros: Long, val samples: List<Sample>) : Message()
    data class Ping(val seq: Long, val senderMicros: Long) : Message()
    data class Pong(val seq: Long, val echoedMicros: Long, val responderMicros: Long) : Message()
    data class Mode(val mode: Int, val flags: Int) : Message()
    data class Key(val keyCode: Int, val modifiers: Int, val action: Int) : Message()
    data class PenButton(val kind: Int) : Message()
    data class Stats(val latencyMicros: Long, val eventsPerSec: Int) : Message()
    /** Tablet → Mac: start/stop mirroring the Mac screen, scaled to fit maxWidth × maxHeight. */
    data class Mirror(val on: Int, val maxWidth: Int, val maxHeight: Int) : Message()
    /** Mac → tablet: H.264 parameters (SPS/PPS without start codes). */
    class VideoConfig(val width: Int, val height: Int, val sps: ByteArray, val pps: ByteArray) : Message() {
        fun same(o: VideoConfig?) = o != null && width == o.width && height == o.height && sps.contentEquals(o.sps) && pps.contentEquals(o.pps)
    }
    /** Mac → tablet: a piece of one Annex-B access unit (flags: VIDEO_FIRST / VIDEO_LAST / VIDEO_KEY). */
    class Video(val flags: Int, val data: ByteArray) : Message()
    data class Unknown(val type: Int, val payload: ByteArray) : Message()
}

fun unit16(v: Float): Int = (v.coerceIn(0f, 1f) * 65535f + 0.5f).toInt()

object Codec {
    private val MAGIC = byteArrayOf('T'.code.toByte(), 'P'.code.toByte(), 'E'.code.toByte(), 'N'.code.toByte())

    /** Encodes a full frame (length prefix + type + payload). */
    fun encode(m: Message): ByteArray {
        val b = ByteBuffer.allocate(3 + 65535).order(ByteOrder.LITTLE_ENDIAN)
        b.position(2)
        when (m) {
            is Message.Hello -> {
                val n = m.name.toByteArray(Charsets.UTF_8).let { if (it.size > 255) it.copyOf(255) else it }
                b.put(Proto.T_HELLO.toByte()).put(MAGIC).putShort(m.version.toShort()).put(m.role.toByte())
                    .putShort(m.width.toShort()).putShort(m.height.toShort()).putShort(m.refreshX10.toShort()).putShort(m.dpi.toShort())
                    .put(n.size.toByte()).put(n)
            }
            is Message.Input -> {
                require(m.samples.size in 1..255) { "1..255 samples per batch" }
                b.put(Proto.T_INPUT.toByte()).putLong(m.baseMicros).put(m.samples.size.toByte())
                for (s in m.samples) putSample(b, s)
            }
            is Message.Ping -> b.put(Proto.T_PING.toByte()).putInt(m.seq.toInt()).putLong(m.senderMicros)
            is Message.Pong -> b.put(Proto.T_PONG.toByte()).putInt(m.seq.toInt()).putLong(m.echoedMicros).putLong(m.responderMicros)
            is Message.Mode -> b.put(Proto.T_MODE.toByte()).put(m.mode.toByte()).put(m.flags.toByte())
            is Message.Key -> b.put(Proto.T_KEY.toByte()).putShort(m.keyCode.toShort()).put(m.modifiers.toByte()).put(m.action.toByte())
            is Message.PenButton -> b.put(Proto.T_PENBTN.toByte()).put(m.kind.toByte())
            is Message.Stats -> b.put(Proto.T_STATS.toByte()).putInt(m.latencyMicros.toInt()).putShort(m.eventsPerSec.toShort())
            is Message.Mirror -> b.put(Proto.T_MIRROR.toByte()).put(m.on.toByte()).putShort(m.maxWidth.toShort()).putShort(m.maxHeight.toShort())
            is Message.VideoConfig -> b.put(Proto.T_VIDEOCFG.toByte()).putShort(m.width.toShort()).putShort(m.height.toShort())
                .putShort(m.sps.size.toShort()).put(m.sps).putShort(m.pps.size.toShort()).put(m.pps)
            is Message.Video -> b.put(Proto.T_VIDEO.toByte()).put(m.flags.toByte()).put(m.data)
            is Message.Unknown -> b.put(m.type.toByte()).put(m.payload)
        }
        val len = b.position() - 2
        b.putShort(0, len.toShort())
        return b.array().copyOf(b.position())
    }

    fun putSample(b: ByteBuffer, s: Sample) {
        b.putInt(s.dtMicros.toInt())
            .put(s.pointerId.toByte())
            .put(((s.action shl 4) or (s.tool and 0xF)).toByte())
            .put(s.flags.toByte())
            .putShort(s.x.toShort()).putShort(s.y.toShort()).putShort(s.pressure.toShort())
            .put(s.tiltX.toByte()).put(s.tiltY.toByte())
            .putShort(s.orientation.toShort())
    }

    /** Decodes one frame body (type + payload, without the length prefix). */
    fun decode(body: ByteArray, offset: Int = 0, length: Int = body.size): Message {
        val b = ByteBuffer.wrap(body, offset, length).order(ByteOrder.LITTLE_ENDIAN)
        val type = b.get().toInt() and 0xFF
        return when (type) {
            Proto.T_HELLO -> {
                val magic = ByteArray(4); b.get(magic)
                require(magic.contentEquals(MAGIC)) { "bad magic" }
                val ver = b.short.toInt() and 0xFFFF
                val role = b.get().toInt() and 0xFF
                val w = b.short.toInt() and 0xFFFF
                val h = b.short.toInt() and 0xFFFF
                val r = b.short.toInt() and 0xFFFF
                val dpi = b.short.toInt() and 0xFFFF
                val n = ByteArray(b.get().toInt() and 0xFF); b.get(n)
                Message.Hello(ver, role, w, h, r, dpi, String(n, Charsets.UTF_8))
            }
            Proto.T_INPUT -> {
                val base = b.long
                val count = b.get().toInt() and 0xFF
                val list = ArrayList<Sample>(count)
                repeat(count) {
                    val dt = b.int.toLong() and 0xFFFFFFFFL
                    val pid = b.get().toInt() and 0xFF
                    val ta = b.get().toInt() and 0xFF
                    val fl = b.get().toInt() and 0xFF
                    val x = b.short.toInt() and 0xFFFF
                    val y = b.short.toInt() and 0xFFFF
                    val p = b.short.toInt() and 0xFFFF
                    val tx = b.get().toInt()
                    val ty = b.get().toInt()
                    val o = b.short.toInt() and 0xFFFF
                    list += Sample(dt, pid, ta and 0xF, ta shr 4, fl, x, y, p, tx, ty, o)
                }
                Message.Input(base, list)
            }
            Proto.T_PING -> Message.Ping(b.int.toLong() and 0xFFFFFFFFL, b.long)
            Proto.T_PONG -> Message.Pong(b.int.toLong() and 0xFFFFFFFFL, b.long, b.long)
            Proto.T_MODE -> Message.Mode(b.get().toInt() and 0xFF, b.get().toInt() and 0xFF)
            Proto.T_KEY -> Message.Key(b.short.toInt() and 0xFFFF, b.get().toInt() and 0xFF, b.get().toInt() and 0xFF)
            Proto.T_PENBTN -> Message.PenButton(b.get().toInt() and 0xFF)
            Proto.T_STATS -> Message.Stats(b.int.toLong() and 0xFFFFFFFFL, b.short.toInt() and 0xFFFF)
            Proto.T_MIRROR -> Message.Mirror(b.get().toInt() and 0xFF, b.short.toInt() and 0xFFFF, b.short.toInt() and 0xFFFF)
            Proto.T_VIDEOCFG -> {
                val w = b.short.toInt() and 0xFFFF
                val h = b.short.toInt() and 0xFFFF
                val sps = ByteArray(b.short.toInt() and 0xFFFF); b.get(sps)
                val pps = ByteArray(b.short.toInt() and 0xFFFF); b.get(pps)
                Message.VideoConfig(w, h, sps, pps)
            }
            Proto.T_VIDEO -> Message.Video(b.get().toInt() and 0xFF, ByteArray(b.remaining()).also { b.get(it) })
            else -> Message.Unknown(type, ByteArray(b.remaining()).also { b.get(it) })
        }
    }
}

/** Incremental stream splitter: feed arbitrary chunks, get complete messages out. */
class FrameReader {
    private var buf = ByteArray(4096)
    private var len = 0

    fun feed(data: ByteArray, count: Int = data.size, out: (Message) -> Unit) {
        if (len + count > buf.size) buf = buf.copyOf(maxOf(buf.size * 2, len + count))
        System.arraycopy(data, 0, buf, len, count)
        len += count
        var pos = 0
        while (len - pos >= 2) {
            val n = (buf[pos].toInt() and 0xFF) or ((buf[pos + 1].toInt() and 0xFF) shl 8)
            if (n == 0) { pos += 2; continue }
            if (len - pos - 2 < n) break
            out(Codec.decode(buf, pos + 2, n))
            pos += 2 + n
        }
        if (pos > 0) { System.arraycopy(buf, pos, buf, 0, len - pos); len -= pos }
    }
}
