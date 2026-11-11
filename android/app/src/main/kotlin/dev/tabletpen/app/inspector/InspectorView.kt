package dev.tabletpen.app.inspector

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.os.Build
import android.os.SystemClock
import android.util.Log
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import kotlin.math.max
import kotlin.math.min

/**
 * Raw input capture surface for M0. Logs every MotionEvent field (including historical
 * samples) to logcat under tag [TAG] and keeps per-tool statistics for the on-screen panel.
 *
 * logcat line kinds:  DEV (axis ranges, once per device), EV (one per MotionEvent),
 * KEY (KeyEvents, e.g. the pen's Bluetooth button), STAT (1 Hz per-tool summary).
 */
class InspectorView(context: Context) : View(context) {

    class ToolStats(val name: String) {
        var events = 0L
        var samples = 0L
        var windowSamples = 0
        var windowEvents = 0
        var samplesPerSec = 0
        var eventsPerSec = 0
        var maxHistory = 0
        var pMin = Float.MAX_VALUE
        var pMax = -Float.MAX_VALUE
        var tiltMaxDeg = 0f
        var tiltSeen = false
        var orientMin = Float.MAX_VALUE
        var orientMax = -Float.MAX_VALUE
        var distMax = 0f
        var hoverEvents = 0L
        var buttonsSeen = 0
        var minDtMicros = Long.MAX_VALUE
        var dtSumMicros = 0L
        var dtCount = 0L
        var lastSampleNanos = 0L
        val pressureValues = HashSet<Int>()
    }

    data class Snapshot(val lastEvent: String, val stats: String, val keys: String, val device: String)

    var onSnapshot: ((Snapshot) -> Unit)? = null

    private val stats = LinkedHashMap<Int, ToolStats>()
    private val seenDevices = HashSet<Int>()
    private var deviceText = "(no input yet)"
    private var lastEventText = "Touch or hover here with fingers and the pen"
    private val keyLog = ArrayDeque<String>()
    private var lastWindow = SystemClock.uptimeMillis()
    private var lastPublish = 0L

    // Trail of recent points: x, y, pressure, kind (0 finger, 1 pen contact, 2 hover)
    private val trail = FloatArray(4 * 4000)
    private var trailHead = 0
    private var trailCount = 0
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)

    init {
        isFocusable = true
        isFocusableInTouchMode = true
        setBackgroundColor(Color.rgb(16, 16, 20))
    }

    fun reset() {
        stats.clear(); keyLog.clear(); trailCount = 0; trailHead = 0
        lastEventText = "(reset)"
        Log.i(TAG, "RESET")
        publish(true); invalidate()
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        requestFocus()
        if (Build.VERSION.SDK_INT >= 30) {
            // Unbuffered hover + stylus streams as well as touch.
            requestUnbufferedDispatch(InputDevice.SOURCE_CLASS_POINTER)
        }
    }

    override fun onTouchEvent(e: MotionEvent): Boolean {
        if (e.actionMasked == MotionEvent.ACTION_DOWN) requestUnbufferedDispatch(e)
        record(e, "touch"); return true
    }

    override fun onHoverEvent(e: MotionEvent): Boolean { record(e, "hover"); return true }

    override fun onGenericMotionEvent(e: MotionEvent): Boolean { record(e, "generic"); return true }

    fun recordKey(e: KeyEvent) {
        val dev = e.device
        val line = "${if (e.action == KeyEvent.ACTION_DOWN) "DOWN" else "UP"} " +
            "${KeyEvent.keyCodeToString(e.keyCode)} scan=${e.scanCode} meta=0x${e.metaState.toString(16)} " +
            "src=0x${e.source.toString(16)} dev='${dev?.name}' rpt=${e.repeatCount}"
        Log.i(TAG, "KEY $line")
        keyLog.addFirst(line)
        while (keyLog.size > 8) keyLog.removeLast()
        publish(true)
    }

    private fun toolName(t: Int) = when (t) {
        MotionEvent.TOOL_TYPE_FINGER -> "FINGER"
        MotionEvent.TOOL_TYPE_STYLUS -> "STYLUS"
        MotionEvent.TOOL_TYPE_ERASER -> "ERASER"
        MotionEvent.TOOL_TYPE_MOUSE -> "MOUSE"
        else -> "UNKNOWN($t)"
    }

    private fun buttons(b: Int): String {
        if (b == 0) return "none"
        val s = ArrayList<String>()
        if (b and MotionEvent.BUTTON_PRIMARY != 0) s += "PRIMARY"
        if (b and MotionEvent.BUTTON_SECONDARY != 0) s += "SECONDARY"
        if (b and MotionEvent.BUTTON_TERTIARY != 0) s += "TERTIARY"
        if (b and MotionEvent.BUTTON_STYLUS_PRIMARY != 0) s += "STYLUS_PRIMARY"
        if (b and MotionEvent.BUTTON_STYLUS_SECONDARY != 0) s += "STYLUS_SECONDARY"
        s += "(0x${b.toString(16)})"
        return s.joinToString("|")
    }

    private fun describeDevice(dev: InputDevice?) {
        if (dev == null || !seenDevices.add(dev.id)) return
        val sb = StringBuilder()
        sb.append("'${dev.name}' id=${dev.id} vid=0x${dev.vendorId.toString(16)} pid=0x${dev.productId.toString(16)} sources=0x${dev.sources.toString(16)}\n")
        Log.i(TAG, "DEV name='${dev.name}' id=${dev.id} vendor=0x${dev.vendorId.toString(16)} product=0x${dev.productId.toString(16)} sources=0x${dev.sources.toString(16)} external=${dev.isExternal}")
        for (r in dev.motionRanges) {
            val line = "axis=${MotionEvent.axisToString(r.axis)} src=0x${r.source.toString(16)} min=${r.min} max=${r.max} flat=${r.flat} fuzz=${r.fuzz} res=${r.resolution}"
            Log.i(TAG, "DEV  $line")
            if (r.axis == MotionEvent.AXIS_PRESSURE || r.axis == MotionEvent.AXIS_TILT ||
                r.axis == MotionEvent.AXIS_ORIENTATION || r.axis == MotionEvent.AXIS_DISTANCE ||
                r.axis == MotionEvent.AXIS_X || r.axis == MotionEvent.AXIS_Y) {
                sb.append("  ${MotionEvent.axisToString(r.axis).removePrefix("AXIS_")} src=0x${r.source.toString(16)} ${r.min}..${r.max} res=${r.resolution}\n")
            }
        }
        deviceText = if (seenDevices.size == 1) sb.toString() else deviceText + sb.toString()
    }

    private fun record(e: MotionEvent, path: String) {
        describeDevice(e.device)
        val action = MotionEvent.actionToString(e.action)
        val isHover = e.actionMasked == MotionEvent.ACTION_HOVER_MOVE ||
            e.actionMasked == MotionEvent.ACTION_HOVER_ENTER || e.actionMasked == MotionEvent.ACTION_HOVER_EXIT
        val hist = e.historySize

        for (p in 0 until e.pointerCount) {
            val tool = e.getToolType(p)
            val st = stats.getOrPut(tool) { ToolStats(toolName(tool)) }
            if (p == 0) { st.events++; st.windowEvents++ }
            if (isHover) st.hoverEvents++
            st.maxHistory = max(st.maxHistory, hist)
            st.buttonsSeen = st.buttonsSeen or e.buttonState
            for (h in 0..hist) {
                val last = h == hist
                val tNanos = if (last) e.eventTimeNanosCompat() else e.getHistoricalEventTimeNanosCompat(h)
                val x = if (last) e.getX(p) else e.getHistoricalX(p, h)
                val y = if (last) e.getY(p) else e.getHistoricalY(p, h)
                val pr = if (last) e.getPressure(p) else e.getHistoricalPressure(p, h)
                val tilt = if (last) e.getAxisValue(MotionEvent.AXIS_TILT, p) else e.getHistoricalAxisValue(MotionEvent.AXIS_TILT, p, h)
                val ori = if (last) e.getOrientation(p) else e.getHistoricalOrientation(p, h)
                val dist = if (last) e.getAxisValue(MotionEvent.AXIS_DISTANCE, p) else e.getHistoricalAxisValue(MotionEvent.AXIS_DISTANCE, p, h)
                st.samples++; st.windowSamples++
                if (!isHover) {
                    st.pMin = min(st.pMin, pr); st.pMax = max(st.pMax, pr)
                    if (st.pressureValues.size < 20000) st.pressureValues.add((pr * 100000).toInt())
                }
                val tiltDeg = Math.toDegrees(tilt.toDouble()).toFloat()
                if (tilt != 0f) st.tiltSeen = true
                st.tiltMaxDeg = max(st.tiltMaxDeg, tiltDeg)
                st.orientMin = min(st.orientMin, ori); st.orientMax = max(st.orientMax, ori)
                st.distMax = max(st.distMax, dist)
                if (p == 0) {
                    if (st.lastSampleNanos != 0L) {
                        val dt = (tNanos - st.lastSampleNanos) / 1000
                        if (dt in 1..100_000) {
                            st.minDtMicros = min(st.minDtMicros, dt); st.dtSumMicros += dt; st.dtCount++
                        }
                    }
                    st.lastSampleNanos = tNanos
                }
                val kind = if (tool == MotionEvent.TOOL_TYPE_FINGER) 0f else if (isHover) 2f else 1f
                val i = trailHead * 4
                trail[i] = x; trail[i + 1] = y; trail[i + 2] = pr; trail[i + 3] = kind
                trailHead = (trailHead + 1) % 4000
                trailCount = min(trailCount + 1, 4000)
            }
            if (e.actionMasked == MotionEvent.ACTION_UP || e.actionMasked == MotionEvent.ACTION_HOVER_EXIT ||
                e.actionMasked == MotionEvent.ACTION_CANCEL) st.lastSampleNanos = 0L
        }

        val tiltDeg = Math.toDegrees(e.getAxisValue(MotionEvent.AXIS_TILT).toDouble())
        val oriDeg = Math.toDegrees(e.orientation.toDouble())
        Log.i(TAG, "EV path=$path act=$action tool=${toolName(e.getToolType(0))} n=${e.pointerCount} hist=$hist " +
            "x=%.1f y=%.1f p=%.5f size=%.4f tilt=%.2f orient=%.2f dist=%.3f btn=%s src=0x%x flags=0x%x t=%d".format(
                e.x, e.y, e.pressure, e.size, tiltDeg, oriDeg, e.getAxisValue(MotionEvent.AXIS_DISTANCE),
                buttons(e.buttonState), e.source, e.flags, e.eventTime))

        lastEventText = buildString {
            append("path=$path  action=$action\n")
            append("tool=${toolName(e.getToolType(0))}  pointers=${e.pointerCount}  history=$hist\n")
            append("x=%.1f  y=%.1f  (view %dx%d)\n".format(e.x, e.y, width, height))
            append("pressure=%.5f  size=%.4f\n".format(e.pressure, e.size))
            append("tilt=%.2f°  orientation=%.2f°  distance=%.3f\n".format(tiltDeg, oriDeg, e.getAxisValue(MotionEvent.AXIS_DISTANCE)))
            append("buttons=${buttons(e.buttonState)}\n")
            append("source=0x${e.source.toString(16)}  flags=0x${e.flags.toString(16)}  dev='${e.device?.name}'")
        }
        rollWindow()
        publish(false)
        postInvalidateOnAnimation()
    }

    private fun rollWindow() {
        val now = SystemClock.uptimeMillis()
        val el = now - lastWindow
        if (el < 1000) return
        for (st in stats.values) {
            st.samplesPerSec = (st.windowSamples * 1000L / el).toInt()
            st.eventsPerSec = (st.windowEvents * 1000L / el).toInt()
            if (st.windowSamples > 0) Log.i(TAG, "STAT ${statLine(st)}")
            st.windowSamples = 0; st.windowEvents = 0
        }
        lastWindow = now
    }

    private fun statLine(st: ToolStats): String {
        val avgDt = if (st.dtCount > 0) st.dtSumMicros / st.dtCount else 0
        val hz = if (avgDt > 0) 1_000_000 / avgDt else 0
        return "${st.name}: ${st.samplesPerSec} samples/s in ${st.eventsPerSec} events/s, maxHist=${st.maxHistory}, " +
            "dt avg=${avgDt}us (~${hz}Hz) min=${if (st.minDtMicros == Long.MAX_VALUE) 0 else st.minDtMicros}us, " +
            "pressure=${if (st.pMax < st.pMin) "n/a" else "%.4f..%.4f".format(st.pMin, st.pMax)} distinct=${st.pressureValues.size}, " +
            "tiltMax=%.1f° tiltSeen=${st.tiltSeen}, orient=%.2f..%.2f rad, distMax=%.2f, hoverEv=${st.hoverEvents}, buttonsSeen=${buttons(st.buttonsSeen)}, total=${st.samples}"
                .format(st.tiltMaxDeg, if (st.orientMax < st.orientMin) 0f else st.orientMin, if (st.orientMax < st.orientMin) 0f else st.orientMax, st.distMax)
    }

    private fun publish(force: Boolean) {
        val now = SystemClock.uptimeMillis()
        if (!force && now - lastPublish < 80) return
        lastPublish = now
        onSnapshot?.invoke(
            Snapshot(
                lastEventText,
                stats.values.joinToString("\n\n") { statLine(it).replace(", ", "\n  ") },
                if (keyLog.isEmpty()) "(none yet — press the pen button, both hovering and away from the screen)" else keyLog.joinToString("\n"),
                deviceText,
            )
        )
    }

    override fun onDraw(c: Canvas) {
        val start = (trailHead - trailCount + 4000) % 4000
        for (k in 0 until trailCount) {
            val i = ((start + k) % 4000) * 4
            val kind = trail[i + 3]
            paint.color = when (kind) { 0f -> Color.rgb(80, 160, 255); 1f -> Color.rgb(255, 200, 60); else -> Color.rgb(120, 120, 120) }
            val r = if (kind == 2f) 2f else 2f + trail[i + 2] * 14f
            c.drawCircle(trail[i], trail[i + 1], r, paint)
        }
    }

    private fun MotionEvent.eventTimeNanosCompat(): Long =
        if (Build.VERSION.SDK_INT >= 34) eventTimeNanos else eventTime * 1_000_000

    private fun MotionEvent.getHistoricalEventTimeNanosCompat(h: Int): Long =
        if (Build.VERSION.SDK_INT >= 34) getHistoricalEventTimeNanos(h) else getHistoricalEventTime(h) * 1_000_000

    companion object { const val TAG = "TPInspect" }
}
