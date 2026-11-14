package dev.tabletpen.app.net

import android.util.Log
import dev.tabletpen.app.protocol.Codec
import dev.tabletpen.app.protocol.FrameReader
import dev.tabletpen.app.protocol.Message
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.LinkedBlockingQueue
import kotlin.concurrent.thread

/**
 * TCP link to the Mac. Over USB the Mac runs `adb reverse`, so the tablet connects to
 * 127.0.0.1 and the connection is tunnelled through the cable. Reconnects forever.
 *
 * Input is never sent from the UI thread (Android forbids network I/O there); frames go through
 * a queue to a dedicated writer thread. TCP_NODELAY is on, so each frame leaves immediately.
 */
class Link(
    private val host: String = "127.0.0.1",
    private val port: Int = dev.tabletpen.app.protocol.Proto.PORT,
    private val hello: () -> Message,
    private val onConnected: (Boolean) -> Unit,
    private val onMessage: (Message) -> Unit,
) {
    @Volatile private var running = false
    @Volatile var connected = false
        private set
    private val queue = LinkedBlockingQueue<ByteArray>(4096)
    private var worker: Thread? = null

    fun start() {
        if (running) return
        running = true
        worker = thread(name = "tp-link", priority = Thread.MAX_PRIORITY) { loop() }
    }

    fun stop() {
        running = false
        worker?.interrupt()
    }

    /** Safe from any thread. Dropped when not connected. */
    fun send(m: Message) {
        if (connected) queue.offer(Codec.encode(m))
    }

    private fun loop() {
        while (running) {
            var socket: Socket? = null
            try {
                socket = Socket()
                socket.tcpNoDelay = true
                socket.connect(InetSocketAddress(host, port), 1000)
                val out = socket.getOutputStream()
                val input = socket.getInputStream()
                queue.clear()
                out.write(Codec.encode(hello())); out.flush()
                connected = true
                onConnected(true)
                Log.i(TAG, "connected to $host:$port")
                val s = socket
                val writer = thread(name = "tp-link-writer", priority = Thread.MAX_PRIORITY) {
                    try {
                        while (!s.isClosed) {
                            out.write(queue.take())
                            // Drain anything queued meanwhile into the same segment.
                            while (true) { out.write(queue.poll() ?: break) }
                            out.flush()
                        }
                    } catch (_: Exception) {
                        try { s.close() } catch (_: Exception) {}
                    }
                }
                val reader = FrameReader()
                val buf = ByteArray(65536)
                while (running) {
                    val n = input.read(buf)
                    if (n < 0) break
                    reader.feed(buf, n) { onMessage(it) }
                }
                writer.interrupt()
            } catch (_: Exception) {
            } finally {
                try { socket?.close() } catch (_: Exception) {}
                if (connected) { connected = false; onConnected(false); Log.i(TAG, "disconnected") }
            }
            try { Thread.sleep(700) } catch (_: InterruptedException) {}
        }
    }

    companion object { const val TAG = "TPLink" }
}
