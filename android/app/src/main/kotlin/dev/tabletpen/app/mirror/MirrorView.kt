package dev.tabletpen.app.mirror

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.RectF
import android.view.MotionEvent
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.ViewGroup
import dev.tabletpen.app.input.CaptureView
import dev.tabletpen.app.protocol.Message
import kotlin.math.hypot

enum class MirrorTool { Control, Draw, Erase }

/** One doodle stroke. Points are (x, y, pressure) with x/y in 0..1 of the mirrored picture. */
class InkStroke(val color: Int, val width: Float) {
    var pts = FloatArray(96); var n = 0
    fun add(x: Float, y: Float, p: Float) {
        if (n > 0 && pts[n * 3 - 3] == x && pts[n * 3 - 2] == y) return
        if (n * 3 + 3 > pts.size) pts = pts.copyOf(pts.size * 2)
        pts[n * 3] = x; pts[n * 3 + 1] = y; pts[n * 3 + 2] = p; n++
    }
}

/** The doodles over the mirrored screen. Tablet-only and not saved: they are notes on what is on screen now. */
class MirrorInk {
    var strokes = ArrayList<InkStroke>()
        private set
    private val undo = ArrayList<ArrayList<InkStroke>>()
    private val redo = ArrayList<ArrayList<InkStroke>>()
    var onChanged: (() -> Unit)? = null
    val canUndo get() = undo.isNotEmpty()
    val canRedo get() = redo.isNotEmpty()

    /** Call before changing `strokes`; the previous state becomes one undo step. */
    fun checkpoint() { undo += ArrayList(strokes); if (undo.size > 200) undo.removeAt(0); redo.clear() }
    fun changed() { onChanged?.invoke() }
    fun add(s: InkStroke) { checkpoint(); strokes += s; changed() }
    fun clear() { if (strokes.isEmpty()) return; checkpoint(); strokes = ArrayList(); changed() }
    fun undo() { if (undo.isEmpty()) return; redo += strokes; strokes = undo.removeAt(undo.size - 1); changed() }
    fun redo() { if (redo.isEmpty()) return; undo += strokes; strokes = redo.removeAt(redo.size - 1); changed() }
}

/**
 * Transparent layer on top of the mirrored picture. Fingers always control the Mac (they act where
 * they touch). The pen either controls the Mac too (tool Control) or draws / erases doodles that
 * exist only on the tablet.
 */
class MirrorOverlay(context: Context, send: (Message) -> Unit, private val ink: MirrorInk) : CaptureView(context, send) {
    var tool = MirrorTool.Draw
        set(v) { field = v; hovering = false; invalidate() }
    var color = Color.rgb(30, 91, 216)
    var strokeWidth = 4f

    private var current: InkStroke? = null
    private var erasedAny = false
    private var hovering = false
    private var hx = 0f; private var hy = 0f
    private var cache: Bitmap? = null
    private var cacheCanvas: Canvas? = null
    private var cacheDirty = true
    private val density = resources.displayMetrics.density
    private val eraseRadius = 14f * density
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeCap = Paint.Cap.ROUND }
    private val ring = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = 3f; color = Color.rgb(255, 120, 120) }

    init {
        setBackgroundColor(Color.TRANSPARENT)
        showContacts = false
        penSink = { e -> if (tool == MirrorTool.Control && e.getToolType(0) != MotionEvent.TOOL_TYPE_ERASER) false else { pen(e); true } }
        ink.onChanged = { cacheDirty = true; invalidate() }
    }

    fun placeArea(r: RectF) { area = r; cacheDirty = true; invalidate() }

    private fun nx(x: Float) = (x - (area?.left ?: 0f)) / (area?.width() ?: width.toFloat()).coerceAtLeast(1f)
    private fun ny(y: Float) = (y - (area?.top ?: 0f)) / (area?.height() ?: height.toFloat()).coerceAtLeast(1f)
    private fun sx(x: Float) = (area?.left ?: 0f) + x * (area?.width() ?: width.toFloat())
    private fun sy(y: Float) = (area?.top ?: 0f) + y * (area?.height() ?: height.toFloat())

    private fun pen(e: MotionEvent) {
        val erasing = tool == MirrorTool.Erase || e.getToolType(0) == MotionEvent.TOOL_TYPE_ERASER
        when (e.actionMasked) {
            MotionEvent.ACTION_HOVER_ENTER, MotionEvent.ACTION_HOVER_MOVE -> { hovering = erasing; hx = e.x; hy = e.y; if (erasing) invalidate() }
            MotionEvent.ACTION_HOVER_EXIT -> { hovering = false; invalidate() }
            MotionEvent.ACTION_DOWN -> {
                if (erasing) { erasedAny = false; hovering = true; erase(e) }
                else { current = InkStroke(color, strokeWidth).also { it.add(nx(e.x), ny(e.y), e.pressure) } }
                invalidate()
            }
            MotionEvent.ACTION_MOVE -> {
                if (erasing) erase(e)
                else current?.let { s ->
                    for (h in 0 until e.historySize) s.add(nx(e.getHistoricalX(h)), ny(e.getHistoricalY(h)), e.getHistoricalPressure(h))
                    s.add(nx(e.x), ny(e.y), e.pressure)
                }
                invalidate()
            }
            MotionEvent.ACTION_UP -> {
                current?.let { s ->
                    current = null
                    ink.onChanged = null                      // append to the cached picture instead of redrawing everything
                    ink.add(s)
                    ink.onChanged = { cacheDirty = true; invalidate() }
                    cacheCanvas?.let { if (!cacheDirty) drawStroke(it, s) }
                    onInkChanged?.invoke()
                }
                invalidate()
            }
            MotionEvent.ACTION_CANCEL -> { current = null; invalidate() }
        }
    }

    /** Fires after any change to the doodles (for the toolbar's undo/redo state). */
    var onInkChanged: (() -> Unit)? = null

    private fun erase(e: MotionEvent) {
        hx = e.x; hy = e.y
        val hit = ink.strokes.filter { s -> (0 until s.n).any { hypot(sx(s.pts[it * 3]) - e.x, sy(s.pts[it * 3 + 1]) - e.y) < eraseRadius } }
        if (hit.isEmpty()) return
        if (!erasedAny) { ink.checkpoint(); erasedAny = true }
        ink.strokes.removeAll(hit.toSet())
        ink.changed()
        onInkChanged?.invoke()
    }

    private fun drawStroke(c: Canvas, s: InkStroke) {
        paint.color = s.color
        val base = s.width * density
        if (s.n == 1) { paint.strokeWidth = base; c.drawPoint(sx(s.pts[0]), sy(s.pts[1]), paint); return }
        for (i in 1 until s.n) {
            val a = (i - 1) * 3; val b = i * 3
            paint.strokeWidth = base * (0.45f + 0.9f * (s.pts[a + 2] + s.pts[b + 2]) / 2)
            c.drawLine(sx(s.pts[a]), sy(s.pts[a + 1]), sx(s.pts[b]), sy(s.pts[b + 1]), paint)
        }
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        cache = null; cacheCanvas = null; cacheDirty = true
    }

    override fun onDraw(c: Canvas) {
        super.onDraw(c)
        if (width == 0 || height == 0) return
        if (cache == null) { cache = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888).also { cacheCanvas = Canvas(it) }; cacheDirty = true }
        if (cacheDirty) {
            cacheCanvas!!.drawColor(0, PorterDuff.Mode.CLEAR)
            for (s in ink.strokes) drawStroke(cacheCanvas!!, s)
            cacheDirty = false
        }
        c.drawBitmap(cache!!, 0f, 0f, null)
        current?.let { drawStroke(c, it) }
        if (hovering) c.drawCircle(hx, hy, eraseRadius, ring)
    }
}

/**
 * The Mirror tab's content: the decoded Mac screen (a SurfaceView, letterboxed to the video's
 * aspect ratio) with the input + doodle overlay on top.
 */
class MirrorView(
    context: Context, send: (Message) -> Unit, ink: MirrorInk,
    private val client: MirrorClient,
    /** Laid out: size of the picture area and of the whole view, in pixels. */
    private val onArea: (areaW: Int, areaH: Int, viewW: Int, viewH: Int) -> Unit,
    private val onSurface: () -> Unit,
) : ViewGroup(context), SurfaceHolder.Callback {
    val overlay = MirrorOverlay(context, send, ink)
    private val surface = SurfaceView(context)
    private var videoW = 0; private var videoH = 0
    private val rect = RectF()

    init {
        addView(surface); addView(overlay)
        surface.holder.addCallback(this)
    }

    fun setVideoSize(w: Int, h: Int) { if (w != videoW || h != videoH) { videoW = w; videoH = h; requestLayout() } }

    override fun onMeasure(wSpec: Int, hSpec: Int) {
        setMeasuredDimension(getDefaultSize(0, wSpec), getDefaultSize(0, hSpec))
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        val w = r - l; val h = b - t
        if (w <= 0 || h <= 0) return
        // Until the stream says otherwise, assume a MacBook's 16:10-ish screen.
        val aspect = if (videoW > 0 && videoH > 0) videoW.toFloat() / videoH else 1.54f
        var aw = w; var ah = (w / aspect).toInt()
        if (ah > h) { ah = h; aw = (h * aspect).toInt() }
        val ax = (w - aw) / 2; val ay = (h - ah) / 2
        surface.measure(MeasureSpec.makeMeasureSpec(aw, MeasureSpec.EXACTLY), MeasureSpec.makeMeasureSpec(ah, MeasureSpec.EXACTLY))
        surface.layout(ax, ay, ax + aw, ay + ah)
        overlay.measure(MeasureSpec.makeMeasureSpec(w, MeasureSpec.EXACTLY), MeasureSpec.makeMeasureSpec(h, MeasureSpec.EXACTLY))
        overlay.layout(0, 0, w, h)
        val nr = RectF(ax.toFloat(), ay.toFloat(), (ax + aw).toFloat(), (ay + ah).toFloat())
        if (nr != rect) { rect.set(nr); overlay.placeArea(RectF(nr)); onArea(aw, ah, w, h) }
    }

    override fun surfaceCreated(holder: SurfaceHolder) { client.setSurface(holder.surface); onSurface() }
    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}
    override fun surfaceDestroyed(holder: SurfaceHolder) { client.setSurface(null) }
}
