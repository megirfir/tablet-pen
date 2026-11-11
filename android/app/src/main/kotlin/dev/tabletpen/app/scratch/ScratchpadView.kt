package dev.tabletpen.app.scratch

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.InputDevice
import android.view.MotionEvent
import android.view.View
import java.util.concurrent.Executors
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.hypot
import kotlin.math.max

enum class ScratchTool { Pen, Highlighter, Eraser, Select }

/**
 * Infinite canvas. Pen writes/erases/selects; one finger pans; two fingers pan and zoom.
 * Everything is stored in world coordinates; the view keeps a scale + translation.
 * Images are drawn under the ink so you can write on top of them.
 */
class ScratchpadView(context: Context, val doc: ScratchDoc) : View(context) {
    var tool = ScratchTool.Pen
        set(v) { field = v; if (v != ScratchTool.Select) selected = null; invalidate() }
    var color = Color.rgb(20, 20, 24)
    var strokeWidth = 4f
    var selected: ImageItem? = null
        private set(v) { field = v; onSelection?.invoke(v != null) }
    var onSelection: ((Boolean) -> Unit)? = null

    private var scale = 1f
    private var tx = 0f
    private var ty = 0f

    private var current: Stroke? = null
    private var erased = ArrayList<Pair<Int, Stroke>>()
    private var erasing = false
    private var eraserX = 0f; private var eraserY = 0f
    private var imgStart: FloatArray? = null
    private var resizing = false
    private var lastWX = 0f; private var lastWY = 0f

    private var penNear = false
    private var penTime = 0L
    private var panPointers = 0
    private var panCX = 0f; private var panCY = 0f; private var panSpread = 0f
    private var fingerImage = false

    private val ink = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }
    private val imgPaint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG)
    private val dotPaint = Paint().apply { color = Color.rgb(200, 200, 196) }
    private val selPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; color = Color.rgb(40, 120, 255) }
    private val handlePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(40, 120, 255) }
    private val eraserPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; color = Color.GRAY; strokeWidth = 2f }
    private val rect = RectF()

    private val handler = Handler(Looper.getMainLooper())
    private val saveTask = Runnable { saveNow(false) }

    init {
        setBackgroundColor(Color.rgb(250, 250, 247))
        if (doc.hasSavedView) { scale = doc.viewScale; tx = doc.viewTx; ty = doc.viewTy }
        doc.onChanged = { scheduleSave(); invalidate() }
    }

    // ---- coordinates ----
    private fun wx(sx: Float) = (sx - tx) / scale
    private fun wy(sy: Float) = (sy - ty) / scale

    fun resetView() { scale = 1f; tx = 0f; ty = 0f; scheduleSave(); invalidate() }
    val zoomPercent get() = (scale * 100).toInt()

    /** Places an image centred in the current view, about 45 % of the view's width. */
    fun addImage(file: String, bmp: android.graphics.Bitmap) {
        val w = (width * 0.45f / scale).coerceAtLeast(1f)
        val h = w * bmp.height / bmp.width
        val item = ImageItem(file, wx(width / 2f) - w / 2, wy(height / 2f) - h / 2, w, h, bmp)
        doc.apply(Edit.AddImage(item))
        tool = ScratchTool.Select
        selected = item
        invalidate()
    }

    fun deleteSelected() {
        val s = selected ?: return
        doc.apply(Edit.RemoveImage(doc.images.indexOf(s), s))
        selected = null
    }

    fun clearAll() {
        if (doc.strokes.isEmpty() && doc.images.isEmpty()) return
        doc.apply(Edit.Clear(ArrayList(doc.strokes), ArrayList(doc.images)))
        selected = null
    }

    fun undo() { doc.undo(); if (selected != null && selected !in doc.images) selected = null }
    fun redo() { doc.redo() }

    // ---- saving ----
    private fun scheduleSave() { handler.removeCallbacks(saveTask); handler.postDelayed(saveTask, 800) }

    fun saveNow(blocking: Boolean) {
        handler.removeCallbacks(saveTask)
        doc.viewScale = scale; doc.viewTx = tx; doc.viewTy = ty; doc.hasSavedView = true
        val data = doc.serialize()
        if (blocking) doc.write(data) else io.execute { doc.write(data) }
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        if (Build.VERSION.SDK_INT >= 30) requestUnbufferedDispatch(InputDevice.SOURCE_CLASS_POINTER)
    }

    override fun onDetachedFromWindow() { saveNow(true); super.onDetachedFromWindow() }

    // ---- input ----
    override fun onHoverEvent(e: MotionEvent): Boolean {
        penNear = e.actionMasked != MotionEvent.ACTION_HOVER_EXIT
        penTime = e.eventTime
        if (tool == ScratchTool.Eraser) { eraserX = e.x; eraserY = e.y; erasing = penNear; invalidate() }
        return true
    }

    override fun onTouchEvent(e: MotionEvent): Boolean {
        if (e.actionMasked == MotionEvent.ACTION_DOWN) requestUnbufferedDispatch(e)
        val type = e.getToolType(0)
        if (type == MotionEvent.TOOL_TYPE_STYLUS || type == MotionEvent.TOOL_TYPE_ERASER) {
            penNear = true; penTime = e.eventTime
            if (panPointers > 0) panPointers = 0
            pen(e, type == MotionEvent.TOOL_TYPE_ERASER)
        } else {
            // Palm rejection: ignore fingers while the pen is at the screen or just left it.
            val guarded = (penNear && e.eventTime - penTime < 3000) || e.eventTime - penTime < 250
            if (guarded || current != null) { panPointers = 0; return true }
            fingers(e)
        }
        return true
    }

    private fun pen(e: MotionEvent, eraserEnd: Boolean) {
        val t = if (eraserEnd) ScratchTool.Eraser else tool
        when (t) {
            ScratchTool.Pen, ScratchTool.Highlighter -> draw(e, t == ScratchTool.Highlighter)
            ScratchTool.Eraser -> erase(e)
            ScratchTool.Select -> selectDrag(e)
        }
    }

    private fun draw(e: MotionEvent, highlighter: Boolean) {
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                val c = if (highlighter) (color and 0x00FFFFFF) or 0x59000000 else color
                // Width is in screen pixels at the zoom you draw at, so ink looks the same size as you write.
                current = Stroke(c, (if (highlighter) strokeWidth * 5f else strokeWidth) / scale, highlighter)
                current!!.add(wx(e.x), wy(e.y), e.pressure)
            }
            MotionEvent.ACTION_MOVE -> {
                val s = current ?: return
                for (h in 0 until e.historySize) s.add(wx(e.getHistoricalX(h)), wy(e.getHistoricalY(h)), e.getHistoricalPressure(h))
                s.add(wx(e.x), wy(e.y), e.pressure)
            }
            MotionEvent.ACTION_UP -> { current?.let { doc.apply(Edit.AddStroke(it)) }; current = null }
            MotionEvent.ACTION_CANCEL -> current = null
        }
        postInvalidateOnAnimation()
    }

    private fun erase(e: MotionEvent) {
        val r = ERASER_PX / scale
        fun at(sx: Float, sy: Float) {
            val x = wx(sx); val y = wy(sy)
            var i = doc.strokes.size - 1
            while (i >= 0) {
                val s = doc.strokes[i]
                if (s.hit(x, y, r)) {
                    // Record the index in the original list so undo restores the order.
                    var o = i
                    for (r0 in erased.sortedBy { it.first }) if (r0.first <= o) o++
                    erased.add(Pair(o, s)); doc.strokes.removeAt(i)
                }
                i--
            }
        }
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_MOVE -> {
                if (e.actionMasked == MotionEvent.ACTION_DOWN) erased = ArrayList()
                for (h in 0 until e.historySize) at(e.getHistoricalX(h), e.getHistoricalY(h))
                at(e.x, e.y)
                eraserX = e.x; eraserY = e.y; erasing = true
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                if (erased.isNotEmpty()) doc.record(Edit.RemoveStrokes(erased.sortedBy { it.first }))
                erased = ArrayList(); erasing = false
            }
        }
        postInvalidateOnAnimation()
    }

    private fun imageAt(x: Float, y: Float): ImageItem? = doc.images.lastOrNull { it.contains(x, y) }

    private fun onHandle(img: ImageItem, x: Float, y: Float) =
        hypot(x - (img.x + img.w), y - (img.y + img.h)) < HANDLE_PX * 1.6f / scale

    /** Select / move / resize an image with the pen or (in Select mode) a finger. Returns false if nothing was hit. */
    private fun selectDrag(e: MotionEvent): Boolean {
        val x = wx(e.x); val y = wy(e.y)
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                val sel = selected
                resizing = sel != null && onHandle(sel, x, y)
                if (!resizing) selected = imageAt(x, y)
                val s = selected
                imgStart = s?.let { floatArrayOf(it.x, it.y, it.w, it.h) }
                lastWX = x; lastWY = y
                invalidate()
                return s != null
            }
            MotionEvent.ACTION_MOVE -> {
                val s = selected ?: return false
                if (imgStart == null) return false
                if (resizing) {
                    val nw = max(x - s.x, 24f / scale)
                    s.h = nw * s.h / s.w; s.w = nw
                } else { s.x += x - lastWX; s.y += y - lastWY }
                lastWX = x; lastWY = y
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                val s = selected; val from = imgStart
                if (s != null && from != null) {
                    val to = floatArrayOf(s.x, s.y, s.w, s.h)
                    if (!from.contentEquals(to)) doc.record(Edit.MoveImage(s, from, to))
                }
                imgStart = null; resizing = false
            }
        }
        postInvalidateOnAnimation()
        return true
    }

    private fun fingers(e: MotionEvent) {
        val masked = e.actionMasked
        if (masked == MotionEvent.ACTION_DOWN) {
            fingerImage = tool == ScratchTool.Select && selectDrag(e)
            if (fingerImage) return
        }
        if (fingerImage) {
            if (e.pointerCount == 1) { selectDrag(e); if (masked == MotionEvent.ACTION_UP || masked == MotionEvent.ACTION_CANCEL) fingerImage = false; return }
            // A second finger turns it into a canvas gesture: finish the image drag first.
            val up = MotionEvent.obtain(e); up.action = MotionEvent.ACTION_UP; selectDrag(up); up.recycle()
            fingerImage = false
        }
        if (masked == MotionEvent.ACTION_UP || masked == MotionEvent.ACTION_CANCEL) {
            panPointers = 0; scheduleSave(); return
        }
        // Centroid and spread of the pointers that stay down.
        val skip = if (masked == MotionEvent.ACTION_POINTER_UP) e.actionIndex else -1
        var cx = 0f; var cy = 0f; var n = 0
        for (i in 0 until e.pointerCount) if (i != skip) { cx += e.getX(i); cy += e.getY(i); n++ }
        if (n == 0) return
        cx /= n; cy /= n
        var spread = 0f
        for (i in 0 until e.pointerCount) if (i != skip) spread += hypot(e.getX(i) - cx, e.getY(i) - cy)
        spread /= n
        if (n != panPointers || masked != MotionEvent.ACTION_MOVE) {
            panPointers = n; panCX = cx; panCY = cy; panSpread = spread   // re-anchor when fingers change
            return
        }
        tx += cx - panCX; ty += cy - panCY
        if (n >= 2 && panSpread > 10f && spread > 10f) {
            val k = (spread / panSpread).coerceIn(0.5f, 2f)
            val ns = (scale * k).coerceIn(MIN_SCALE, MAX_SCALE)
            val f = ns / scale
            tx = cx - (cx - tx) * f; ty = cy - (cy - ty) * f     // zoom about the pinch centre
            scale = ns
        }
        panCX = cx; panCY = cy; panSpread = spread
        postInvalidateOnAnimation()
    }

    // ---- drawing ----
    override fun onDraw(c: Canvas) {
        val l = wx(0f); val t = wy(0f); val r = wx(width.toFloat()); val b = wy(height.toFloat())
        // Dot grid that thins out as you zoom out, so the canvas reads as endless.
        var step = 48f
        while (step * scale < 28f) step *= 4f
        val dotR = max(1.5f, 1.6f * scale.coerceAtMost(2f))
        var gy = floor(t / step) * step
        while (gy <= b) {
            var gx = floor(l / step) * step
            while (gx <= r) { c.drawCircle(gx * scale + tx, gy * scale + ty, dotR, dotPaint); gx += step }
            gy += step
        }
        c.save()
        c.translate(tx, ty); c.scale(scale, scale)
        for (im in doc.images) {
            if (im.x > r || im.x + im.w < l || im.y > b || im.y + im.h < t) continue
            rect.set(im.x, im.y, im.x + im.w, im.y + im.h)
            c.drawBitmap(im.bitmap, null, rect, imgPaint)
        }
        for (s in doc.strokes) {
            if (s.minX > r || s.maxX < l || s.minY > b || s.maxY < t) continue
            ink.color = s.color; c.drawPath(s.path, ink)
        }
        current?.let { ink.color = it.color; c.drawPath(it.path, ink) }
        selected?.let { s ->
            selPaint.strokeWidth = 3f / scale
            c.drawRect(s.x, s.y, s.x + s.w, s.y + s.h, selPaint)
            c.drawCircle(s.x + s.w, s.y + s.h, HANDLE_PX / scale, handlePaint)
        }
        c.restore()
        if (erasing && (tool == ScratchTool.Eraser)) c.drawCircle(eraserX, eraserY, ERASER_PX, eraserPaint)
    }

    companion object {
        const val ERASER_PX = 22f
        const val HANDLE_PX = 16f
        const val MIN_SCALE = 0.05f
        const val MAX_SCALE = 16f
        private val io = Executors.newSingleThreadExecutor()
    }
}
