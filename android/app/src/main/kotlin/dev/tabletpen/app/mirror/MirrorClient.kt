package dev.tabletpen.app.mirror

import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import dev.tabletpen.app.protocol.Message
import dev.tabletpen.app.protocol.Proto
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * Receives the Mac's H.264 screen stream (VIDEOCFG + VIDEO pieces) and decodes it straight onto a
 * Surface with the hardware decoder. Thread-safe: messages arrive on the link's reader thread, the
 * surface comes and goes on the UI thread.
 *
 * @param onSize  coded video size, whenever the stream parameters change
 * @param onLive  true once the first picture is on screen, false when the picture is lost
 * @param needKey the decoder cannot continue without a keyframe (ask the Mac for one)
 */
class MirrorClient(
    private val onSize: (Int, Int) -> Unit,
    private val onLive: (Boolean) -> Unit,
    private val needKey: () -> Unit,
) {
    private val lock = Any()
    private var surface: Surface? = null
    private var cfg: Message.VideoConfig? = null
    @Volatile private var codec: MediaCodec? = null
    private val inputs = LinkedBlockingQueue<Int>()
    private var waitKey = true
    private val acc = ByteArrayOutputStream(1 shl 20)
    private var accOk = false
    private var live = false
    private var lastKeyAsk = 0L
    private val thread = HandlerThread("tp-decoder").apply { start() }
    private val handler = Handler(thread.looper)

    fun setSurface(s: Surface?) = synchronized(lock) { surface = s; restart() }

    /** The link dropped: whatever arrives next is a new stream. */
    fun reset() = synchronized(lock) { accOk = false; waitKey = true; setLive(false) }

    fun config(c: Message.VideoConfig) = synchronized(lock) {
        if (c.same(cfg) && codec != null) return
        cfg = c
        onSize(c.width, c.height)
        restart()
    }

    fun video(m: Message.Video) = synchronized(lock) {
        if (m.flags and Proto.VIDEO_FIRST != 0) { acc.reset(); accOk = true }
        if (!accOk) return
        acc.write(m.data)
        if (m.flags and Proto.VIDEO_LAST != 0) {
            accOk = false
            frame(acc.toByteArray(), m.flags and Proto.VIDEO_KEY != 0)
        }
    }

    private fun frame(data: ByteArray, key: Boolean) {
        val c = codec ?: return
        if (waitKey && !key) { askKey(); return }
        try {
            val i = inputs.poll(40, TimeUnit.MILLISECONDS)
            val buf = if (i != null) c.getInputBuffer(i) else null
            if (i == null || buf == null || buf.capacity() < data.size) {
                // Decoder is behind (or the frame is oversized): skip ahead to the next keyframe.
                if (i != null) inputs.offer(i)
                waitKey = true; askKey(); return
            }
            buf.clear(); buf.put(data)
            c.queueInputBuffer(i, 0, data.size, System.nanoTime() / 1000, 0)
            waitKey = false
        } catch (e: Exception) {
            Log.w(TAG, "decoder input failed", e)
            restart(); askKey()
        }
    }

    private fun askKey() {
        val now = System.currentTimeMillis()
        if (now - lastKeyAsk < 400) return
        lastKeyAsk = now
        needKey()
    }

    private fun setLive(v: Boolean) { if (live != v) { live = v; onLive(v) } }

    private fun restart() {
        codec?.let { old -> codec = null; try { old.stop() } catch (_: Exception) {}; try { old.release() } catch (_: Exception) {} }
        inputs.clear()
        waitKey = true
        setLive(false)
        val s = surface; val c = cfg
        if (s == null || !s.isValid || c == null) return
        try {
            val start = byteArrayOf(0, 0, 0, 1)
            val f = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, c.width, c.height)
            f.setByteBuffer("csd-0", ByteBuffer.wrap(start + c.sps))
            f.setByteBuffer("csd-1", ByteBuffer.wrap(start + c.pps))
            f.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 4 shl 20)
            f.setInteger(MediaFormat.KEY_PRIORITY, 0)                                   // realtime
            if (Build.VERSION.SDK_INT >= 30) f.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            val mc = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
            mc.setCallback(object : MediaCodec.Callback() {
                override fun onInputBufferAvailable(m: MediaCodec, index: Int) { if (m === codec) inputs.offer(index) }
                override fun onOutputBufferAvailable(m: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
                    try { m.releaseOutputBuffer(index, true) } catch (_: Exception) {}
                    if (m === codec) synchronized(lock) { if (m === codec) setLive(true) }
                }
                override fun onError(m: MediaCodec, e: MediaCodec.CodecException) {
                    Log.w(TAG, "decoder error", e)
                    synchronized(lock) { if (m === codec) { restart(); askKey() } }
                }
                override fun onOutputFormatChanged(m: MediaCodec, format: MediaFormat) {}
            }, handler)
            mc.configure(f, s, null, 0)
            codec = mc
            mc.start()
            Log.i(TAG, "decoder started ${c.width}x${c.height} (${mc.name})")
        } catch (e: Exception) {
            Log.e(TAG, "could not start the decoder", e)
            codec?.let { try { it.release() } catch (_: Exception) {} }
            codec = null
        }
    }

    companion object { const val TAG = "TPMirror" }
}
