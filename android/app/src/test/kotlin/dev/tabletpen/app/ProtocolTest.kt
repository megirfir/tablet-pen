package dev.tabletpen.app

import dev.tabletpen.app.protocol.*
import org.junit.Assert.*
import org.junit.Test

class ProtocolTest {
    private fun hex(s: String) = s.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    private fun vectors(): Map<String, ByteArray> =
        javaClass.classLoader!!.getResource("frames.txt")!!.readText().lines()
            .filter { it.isNotBlank() && !it.startsWith("#") }
            .associate { it.substringBefore(":").trim() to hex(it.substringAfter(":").trim()) }

    private fun decodeFrame(f: ByteArray): Message {
        var out: Message? = null
        FrameReader().feed(f) { out = it }
        return out!!
    }

    @Test fun vectorsRoundTrip() {
        val v = vectors()
        assertEquals(10, v.size)
        for ((name, bytes) in v) assertArrayEquals(name, bytes, Codec.encode(decodeFrame(bytes)))
    }

    @Test fun inputVectorFields() {
        val m = decodeFrame(vectors()["input"]!!) as Message.Input
        assertEquals(123456789L, m.baseMicros)
        assertEquals(
            listOf(
                Sample(0, 0, Proto.TOOL_PEN, Proto.ACT_HOVER_MOVE, Proto.FLAG_HISTORICAL, 32768, 16384, 0, -10, 5, 49152),
                Sample(4167, 0, Proto.TOOL_PEN, Proto.ACT_DOWN, Proto.FLAG_CONTACT or Proto.FLAG_BTN_PRIMARY, 65535, 0, 40000, 45, -90, 0),
            ), m.samples)
    }

    @Test fun helloVectorFields() {
        assertEquals(Message.Hello(1, 0, 2944, 1840, 1440, 273, "Tab"), decodeFrame(vectors()["hello"]!!))
    }

    @Test fun streamSplitAcrossChunks() {
        val all = vectors().values.fold(ByteArray(0)) { a, b -> a + b }
        for (chunk in listOf(1, 2, 3, 7, 64)) {
            val r = FrameReader(); var n = 0
            var i = 0
            while (i < all.size) {
                val c = minOf(chunk, all.size - i)
                r.feed(all.copyOfRange(i, i + c)) { n++ }
                i += c
            }
            assertEquals("chunk=$chunk", 10, n)
        }
    }

    @Test fun unknownTypeIsSkipped() {
        val frame = hex("0300ee0102") + hex("0300050100")
        val got = ArrayList<Message>()
        FrameReader().feed(frame) { got += it }
        assertTrue(got[0] is Message.Unknown)
        assertEquals(Message.Mode(1, 0), got[1])
    }

    @Test fun unit16Clamps() {
        assertEquals(0, unit16(-1f)); assertEquals(65535, unit16(2f)); assertEquals(32768, unit16(0.5f))
    }

    @Test fun mirrorVectorFields() {
        val v = vectors()
        assertEquals(Message.Mirror(1, 2944, 1700), decodeFrame(v["mirror"]!!))
        val c = decodeFrame(v["videoconfig"]!!) as Message.VideoConfig
        assertEquals(2048, c.width); assertEquals(1408, c.height)
        assertArrayEquals(byteArrayOf(0x67, 0x64, 0x0a), c.sps)
        assertArrayEquals(byteArrayOf(0x68, 0xee.toByte()), c.pps)
        val f = decodeFrame(v["video"]!!) as Message.Video
        assertEquals(7, f.flags)
        assertArrayEquals(byteArrayOf(0, 0, 1, 0x65), f.data)
    }
}
