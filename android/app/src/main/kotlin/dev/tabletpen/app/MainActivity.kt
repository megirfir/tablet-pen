package dev.tabletpen.app

import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.KeyEvent
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import dev.tabletpen.app.input.CaptureView
import dev.tabletpen.app.inspector.InspectorView
import dev.tabletpen.app.net.Link
import dev.tabletpen.app.protocol.Message
import dev.tabletpen.app.protocol.Proto
import dev.tabletpen.app.scratch.ScratchDoc
import dev.tabletpen.app.scratch.ScratchpadScreen
import dev.tabletpen.app.scratch.ScratchpadView
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts

enum class Screen(val label: String) { Trackpad("Trackpad"), Scratchpad("Scratchpad"), Inspector("Inspector") }

class MainActivity : ComponentActivity() {
    private var inspector: InspectorView? = null
    private var screen by mutableStateOf(Screen.Trackpad)
    private var connected by mutableStateOf(false)
    private var macName by mutableStateOf("")
    private var statsText by mutableStateOf("")
    private var surfaceW = 0
    private var surfaceH = 0
    private lateinit var link: Link
    private var scratchView: ScratchpadView? = null
    /** Set by the scratchpad screen: pen button click toggles the eraser, double click undoes. */
    var scratchPenButton: ((Int) -> Unit)? = null
    private val scratchDoc by lazy { ScratchDoc(java.io.File(filesDir, "scratchpad")).also { it.load() } }
    private val pickImage = registerForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) importImage(uri)
    }

    private fun importImage(uri: android.net.Uri) {
        try {
            val src = android.graphics.ImageDecoder.createSource(contentResolver, uri)
            val bmp = android.graphics.ImageDecoder.decodeBitmap(src) { d, info, _ ->
                d.allocator = android.graphics.ImageDecoder.ALLOCATOR_SOFTWARE
                val long = maxOf(info.size.width, info.size.height)
                if (long > 2560) { val k = 2560f / long; d.setTargetSize((info.size.width * k).toInt(), (info.size.height * k).toInt()) }
            }
            scratchView?.addImage(scratchDoc.storeImage(bmp), bmp)
        } catch (e: Exception) {
            Log.e("TPScratch", "image import failed", e)
            android.widget.Toast.makeText(this, "Couldn't read that image", android.widget.Toast.LENGTH_SHORT).show()
        }
    }

    private fun pasteImage() {
        val clip = (getSystemService(CLIPBOARD_SERVICE) as android.content.ClipboardManager).primaryClip
        val uri = (0 until (clip?.itemCount ?: 0)).firstNotNullOfOrNull { clip!!.getItemAt(it).uri }
        if (uri == null) android.widget.Toast.makeText(this, "No image on the clipboard — copy one first, or use Add image", android.widget.Toast.LENGTH_LONG).show()
        else importImage(uri)
    }

    private fun hello(): Message {
        val d = resources.displayMetrics
        val hz = display?.refreshRate ?: 60f
        return Message.Hello(Proto.VERSION, 0, surfaceW, surfaceH, (hz * 10).toInt(), d.xdpi.toInt(), Build.MODEL)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        // Ask for the panel's highest refresh rate (144 Hz on the Idea Tab Pro).
        val best = display?.supportedModes?.maxByOrNull { it.refreshRate }
        if (best != null) window.attributes = window.attributes.also { it.preferredDisplayModeId = best.modeId }
        // Full screen: system bars and edge gestures would steal touches near the edges.
        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowInsetsControllerCompat(window, window.decorView).apply {
            hide(WindowInsetsCompat.Type.systemBars())
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
        val d = resources.displayMetrics
        Log.i(InspectorView.TAG, "SYS model=${Build.MODEL} android=${Build.VERSION.RELEASE} display=${d.widthPixels}x${d.heightPixels} xdpi=${d.xdpi}")

        link = Link(
            hello = ::hello,
            onConnected = { c -> runOnUiThread { connected = c; if (!c) { statsText = ""; macName = "" } } },
            onMessage = { m ->
                when (m) {
                    is Message.Ping -> link.send(Message.Pong(m.seq, m.senderMicros, System.nanoTime() / 1000))
                    is Message.Hello -> runOnUiThread { macName = m.name }
                    is Message.Stats -> runOnUiThread {
                        statsText = "%.1f ms · %d samples/s".format(m.latencyMicros / 1000.0, m.eventsPerSec)
                    }
                    else -> {}
                }
            },
        )

        setContent {
            MaterialTheme(colorScheme = darkColorScheme()) {
                Column(Modifier.fillMaxSize().background(Color.Black)) {
                    TopBar()
                    when (screen) {
                        Screen.Trackpad -> TrackpadScreen()
                        Screen.Scratchpad -> ScratchpadScreen(
                            doc = scratchDoc, onView = { scratchView = it },
                            onPaste = ::pasteImage,
                            onPick = { pickImage.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) },
                        )
                        Screen.Inspector -> InspectorScreen(onView = { inspector = it })
                    }
                }
            }
        }
    }

    override fun onStart() { super.onStart(); link.start() }
    override fun onStop() { super.onStop(); link.stop(); if (screen == Screen.Scratchpad) scratchView?.saveNow(true) }

    @Composable
    private fun TopBar() {
        Row(
            Modifier.fillMaxWidth().background(Color(0xFF1B1B22)).padding(horizontal = 12.dp, vertical = 2.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            for (s in Screen.entries) {
                FilterChip(selected = screen == s, onClick = { screen = s }, label = { Text(s.label) })
                Spacer(Modifier.width(8.dp))
            }
            Spacer(Modifier.weight(1f))
            Text(
                if (connected) "● ${macName.ifEmpty { "Mac" }} (USB)   $statsText" else "○ Waiting for the Mac app…",
                color = if (connected) Color(0xFF7BD88F) else Color(0xFFFFB74D),
                fontSize = 14.sp, fontFamily = FontFamily.Monospace,
            )
        }
    }

    @Composable
    private fun TrackpadScreen() {
        AndroidView(
            factory = { ctx ->
                CaptureView(ctx) { link.send(it) }.also { v ->
                    v.hint = "Trackpad\n1 finger: move · tap: click · 2-finger tap: right-click\n" +
                        "2 fingers: scroll / pinch · double-tap + drag: drag\nPen: hover moves, touch clicks, side button right-clicks"
                    v.addOnLayoutChangeListener { _, l, t, r, b, _, _, _, _ ->
                        if (r - l != surfaceW || b - t != surfaceH) {
                            surfaceW = r - l; surfaceH = b - t
                            link.send(hello())
                        }
                    }
                }
            },
            modifier = Modifier.fillMaxSize(),
        )
    }

    // The Tab Pen Plus side button is not a MotionEvent button; it arrives from the pen's
    // Bluetooth "Consumer Control" device as vendor key codes: 601 click, 602 double, 603 long.
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (screen == Screen.Inspector) inspector?.recordKey(event)
        if (event.keyCode in 601..603) {
            val kind = event.keyCode - 600
            val fire = if (kind == 1) event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0 else event.action == KeyEvent.ACTION_UP
            if (fire) {
                if (screen == Screen.Scratchpad) scratchPenButton?.invoke(kind) else link.send(Message.PenButton(kind))
            }
            return true
        }
        return super.dispatchKeyEvent(event)
    }
}

@Composable
fun InspectorScreen(onView: (InspectorView) -> Unit) {
    var snap by remember { mutableStateOf(InspectorView.Snapshot("Touch or hover on the right with fingers and the pen", "", "", "")) }
    var view by remember { mutableStateOf<InspectorView?>(null) }
    Row(Modifier.fillMaxSize().background(Color.Black)) {
        Column(
            Modifier.width(430.dp).fillMaxHeight().background(Color(0xFF1B1B22)).padding(12.dp)
                .verticalScroll(rememberScrollState())
        ) {
            Row {
                Text("Input inspector", color = Color.White, fontSize = 20.sp, fontWeight = FontWeight.Bold,
                    modifier = Modifier.weight(1f))
                Button(onClick = { view?.reset() }) { Text("Reset") }
            }
            Section("Last event", snap.lastEvent)
            Section("Per-tool stats", snap.stats.ifEmpty { "(no input yet)" })
            Section("Key events (pen button?)", snap.keys)
            Section("Input devices", snap.device)
        }
        Box(Modifier.fillMaxSize()) {
            AndroidView(
                factory = { ctx ->
                    InspectorView(ctx).also { v ->
                        v.onSnapshot = { s -> snap = s }
                        view = v; onView(v)
                    }
                },
                modifier = Modifier.fillMaxSize(),
            )
        }
    }
}

@Composable
private fun Section(title: String, body: String) {
    Spacer(Modifier.height(12.dp))
    Text(title, color = Color(0xFF8AB4F8), fontSize = 13.sp, fontWeight = FontWeight.Bold)
    Text(body, color = Color(0xFFE0E0E0), fontSize = 12.sp, fontFamily = FontFamily.Monospace, lineHeight = 16.sp)
}
