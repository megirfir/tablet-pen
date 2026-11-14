package dev.tabletpen.app.input

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.os.Build
import android.view.InputDevice
import android.view.MotionEvent
import android.view.View
import dev.tabletpen.app.protocol.Message
import dev.tabletpen.app.protocol.Proto
import dev.tabletpen.app.protocol.Sample
import dev.tabletpen.app.protocol.unit16
import kotlin.math.PI
import kotlin.math.atan
import kotlin.math.cos
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.tan

/**
 * The surface that captures pen and touch and turns every MotionEvent — including all of its
 * historical samples — into one INPUT batch. Nothing is throttled or coalesced: the pen delivers
 * ~240 samples/s and all of them are forwarded.
 */
open class CaptureView(context: Context, private val send: (Message) -> Unit) : View(context) {

    var hint: String = ""
        set(value) { field = value; postInvalidate() }

    /** Part of the view (pixels) that maps to 0..1; null = the whole view. Positions outside clamp to its edge. */
    var area: RectF? = null
    /** Sees every pen event first; returning true keeps it on the tablet (nothing is sent to the Mac). */
    var penSink: ((MotionEvent) -> Boolean)? = null
    /** Draw the blue contact dots. */
    var showContacts = true
    private var penRemote = false          // the Mac currently believes the pen is near/on the surface

    private var penNearUntil = 0L          // uptime ms; fingers are ignored until then (palm rejection)
    private var penNear = false
    private var lastPenEvent = 0L
    private var fingersDown = false
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(90, 90, 100); textSize = 34f; textAlign = Paint.Align.CENTER }
    private val dot = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(70, 130, 220) }
    private val px = FloatArray(10); private val py = FloatArray(10); private var pn = 0

    init { setBackgroundColor(Color.rgb(14, 14, 18)) }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        if (Build.VERSION.SDK_INT >= 30) requestUnbufferedDispatch(InputDevice.SOURCE_CLASS_POINTER)
    }

    override fun onTouchEvent(e: MotionEvent): Boolean {
        if (e.actionMasked == MotionEvent.ACTION_DOWN) requestUnbufferedDispatch(e)
        forward(e); return true
    }

    override fun onHoverEvent(e: MotionEvent): Boolean { forward(e); return true }

    private fun tool(t: Int) = when (t) {
        MotionEvent.TOOL_TYPE_STYLUS -> Proto.TOOL_PEN
        MotionEvent.TOOL_TYPE_ERASER -> Proto.TOOL_ERASER
        MotionEvent.TOOL_TYPE_MOUSE -> Proto.TOOL_MOUSE
        else -> Proto.TOOL_FINGER
    }

    private fun forward(e: MotionEvent) {
        val a = area
        val ox = a?.left ?: 0f; val oy = a?.top ?: 0f
        val w = (a?.width() ?: width.toFloat()).coerceAtLeast(1f); val h = (a?.height() ?: height.toFloat()).coerceAtLeast(1f)
        val masked = e.actionMasked
        val isPen = (0 until e.pointerCount).any { e.getToolType(it) == MotionEvent.TOOL_TYPE_STYLUS || e.getToolType(it) == MotionEvent.TOOL_TYPE_ERASER }
        val now = e.eventTime

        if (isPen) {
            penNear = masked != MotionEvent.ACTION_HOVER_EXIT && masked != MotionEvent.ACTION_CANCEL
            lastPenEvent = now
            penNearUntil = now + PALM_GUARD_MS
            if (penSink?.invoke(e) == true) {
                if (penRemote) {
                    // The pen was controlling the Mac a moment ago: release it there, otherwise the
                    // Mac keeps the button held and keeps ignoring fingers as palm touches.
                    penRemote = false
                    val s = Sample(0, e.getPointerId(0), Proto.TOOL_PEN, Proto.ACT_CANCEL, 0,
                        unit16((e.x - ox) / w), unit16((e.y - oy) / h), 0, 0, 0, 32768)
                    send(Message.Input(nanos(e) / 1000, listOf(s, s.copy(action = Proto.ACT_HOVER_EXIT))))
                }
                return
            }
            penRemote = penNear
        } else {
            // Palm rejection: no finger input while the pen is hovering/touching or just left.
            // (penNear expires after 3 s without pen events, in case a hover-exit was missed.)
            if ((penNear && now - lastPenEvent < 3000) || now < penNearUntil) {
                if (masked == MotionEvent.ACTION_UP || masked == MotionEvent.ACTION_CANCEL) fingersDown = false
                return
            }
            // A gesture that began during the guard window is ignored until it ends.
            if (masked == MotionEvent.ACTION_DOWN) fingersDown = true
            else if (!fingersDown) return
            if (masked == MotionEvent.ACTION_UP || masked == MotionEvent.ACTION_CANCEL) fingersDown = false
        }

        val actionIndex = e.actionIndex
        val baseNanos = if (e.historySize > 0) histNanos(e, 0) else nanos(e)
        val samples = ArrayList<Sample>((e.historySize + 1) * e.pointerCount)
        val buttons = (if (e.buttonState and MotionEvent.BUTTON_STYLUS_PRIMARY != 0) Proto.FLAG_BTN_PRIMARY else 0) or
            (if (e.buttonState and MotionEvent.BUTTON_STYLUS_SECONDARY != 0) Proto.FLAG_BTN_SECONDARY else 0)

        for (hI in 0..e.historySize) {
            val last = hI == e.historySize
            val t = if (last) nanos(e) else histNanos(e, hI)
            for (p in 0 until e.pointerCount) {
                val action = if (!last) moveAction(masked) else when (masked) {
                    MotionEvent.ACTION_DOWN -> Proto.ACT_DOWN
                    MotionEvent.ACTION_POINTER_DOWN -> if (p == actionIndex) Proto.ACT_DOWN else Proto.ACT_MOVE
                    MotionEvent.ACTION_UP -> Proto.ACT_UP
                    MotionEvent.ACTION_POINTER_UP -> if (p == actionIndex) Proto.ACT_UP else Proto.ACT_MOVE
                    MotionEvent.ACTION_CANCEL -> Proto.ACT_CANCEL
                    MotionEvent.ACTION_HOVER_ENTER -> Proto.ACT_HOVER_ENTER
                    MotionEvent.ACTION_HOVER_EXIT -> Proto.ACT_HOVER_EXIT
                    MotionEvent.ACTION_HOVER_MOVE -> Proto.ACT_HOVER_MOVE
                    else -> Proto.ACT_MOVE
                }
                val x = if (last) e.getX(p) else e.getHistoricalX(p, hI)
                val y = if (last) e.getY(p) else e.getHistoricalY(p, hI)
                val pr = if (last) e.getPressure(p) else e.getHistoricalPressure(p, hI)
                val tilt = if (last) e.getAxisValue(MotionEvent.AXIS_TILT, p) else e.getHistoricalAxisValue(MotionEvent.AXIS_TILT, p, hI)
                val ori = if (last) e.getOrientation(p) else e.getHistoricalOrientation(p, hI)
                val contact = action == Proto.ACT_DOWN || action == Proto.ACT_MOVE
                // Tilt as X/Y lean angles. Android: orientation 0 = pen points "up" the screen,
                // positive clockwise; tilt = angle from perpendicular.
                val tt = tan(tilt.toDouble().coerceIn(0.0, 1.55))
                val tx = Math.toDegrees(atan(sin(ori.toDouble()) * tt)).roundToInt().coerceIn(-90, 90)
                val ty = Math.toDegrees(atan(-cos(ori.toDouble()) * tt)).roundToInt().coerceIn(-90, 90)
                samples += Sample(
                    dtMicros = ((t - baseNanos) / 1000).coerceAtLeast(0),
                    pointerId = e.getPointerId(p),
                    tool = tool(e.getToolType(p)),
                    action = action,
                    flags = buttons or (if (contact) Proto.FLAG_CONTACT else 0) or (if (!last) Proto.FLAG_HISTORICAL else 0),
                    x = unit16((x - ox) / w), y = unit16((y - oy) / h), pressure = unit16(pr),
                    tiltX = tx, tiltY = ty,
                    orientation = (((ori + PI) / (2 * PI)).coerceIn(0.0, 1.0) * 65535).roundToInt(),
                )
            }
        }
        var i = 0
        while (i < samples.size) {
            val end = minOf(i + 255, samples.size)
            send(Message.Input(baseNanos / 1000, samples.subList(i, end).toList()))
            i = end
        }

        // Light local feedback: where the contacts are.
        pn = if (masked == MotionEvent.ACTION_UP || masked == MotionEvent.ACTION_CANCEL || masked == MotionEvent.ACTION_HOVER_EXIT) 0
        else minOf(e.pointerCount, 10).also { n -> for (k in 0 until n) { px[k] = e.getX(k); py[k] = e.getY(k) } }
        postInvalidateOnAnimation()
    }

    private fun moveAction(masked: Int) =
        if (masked == MotionEvent.ACTION_HOVER_MOVE) Proto.ACT_HOVER_MOVE else Proto.ACT_MOVE

    private fun nanos(e: MotionEvent) = if (Build.VERSION.SDK_INT >= 34) e.eventTimeNanos else e.eventTime * 1_000_000
    private fun histNanos(e: MotionEvent, h: Int) =
        if (Build.VERSION.SDK_INT >= 34) e.getHistoricalEventTimeNanos(h) else e.getHistoricalEventTime(h) * 1_000_000

    override fun onDraw(c: Canvas) {
        if (hint.isNotEmpty()) {
            var y = height / 2f - 20f
            for (line in hint.split("\n")) { c.drawText(line, width / 2f, y, paint); y += 46f }
        }
        if (showContacts) for (k in 0 until pn) c.drawCircle(px[k], py[k], 26f, dot)
    }

    companion object { const val PALM_GUARD_MS = 250L }
}
