package dev.tabletpen.app.scratch

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Path
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

/** One vector stroke in world coordinates: (x, y, pressure) triples plus style. */
class Stroke(val color: Int, val width: Float, val highlighter: Boolean) {
    var pts = FloatArray(192)
        private set
    var n = 0
        private set
    var minX = Float.MAX_VALUE; var minY = Float.MAX_VALUE
    var maxX = -Float.MAX_VALUE; var maxY = -Float.MAX_VALUE

    /** Filled outline, built incrementally as points arrive. */
    val path = Path()

    fun radius(p: Float): Float =
        if (highlighter) width / 2f else width / 2f * (0.3f + 0.9f * pressureCurve(p))

    fun add(x: Float, y: Float, p: Float) {
        if (n > 0) {
            val i = (n - 1) * 3
            if (x == pts[i] && y == pts[i + 1]) return
        }
        if (n * 3 + 3 > pts.size) pts = pts.copyOf(pts.size * 2)
        pts[n * 3] = x; pts[n * 3 + 1] = y; pts[n * 3 + 2] = p
        n++
        val r = radius(p)
        minX = min(minX, x - r); minY = min(minY, y - r); maxX = max(maxX, x + r); maxY = max(maxY, y + r)
        extendPath(n - 1)
    }

    private fun extendPath(i: Int) {
        val x1 = pts[i * 3]; val y1 = pts[i * 3 + 1]; val r1 = radius(pts[i * 3 + 2])
        if (i > 0) {
            val x0 = pts[i * 3 - 3]; val y0 = pts[i * 3 - 2]; val r0 = radius(pts[i * 3 - 1])
            val dx = x1 - x0; val dy = y1 - y0
            val len = hypot(dx, dy)
            if (len > 0f) {
                // Quad around the segment; same winding as the CCW circles so overlaps fill solid.
                val nx = -dy / len; val ny = dx / len
                path.moveTo(x0 + nx * r0, y0 + ny * r0)
                path.lineTo(x1 + nx * r1, y1 + ny * r1)
                path.lineTo(x1 - nx * r1, y1 - ny * r1)
                path.lineTo(x0 - nx * r0, y0 - ny * r0)
                path.close()
            }
        }
        path.addCircle(x1, y1, r1, Path.Direction.CCW)
    }

    /** True if any part of the stroke is within [radius] of (x, y). */
    fun hit(x: Float, y: Float, radius: Float): Boolean {
        if (x < minX - radius || x > maxX + radius || y < minY - radius || y > maxY + radius) return false
        for (i in 0 until n) {
            val r = radius + radius(pts[i * 3 + 2])
            if (hypot(pts[i * 3] - x, pts[i * 3 + 1] - y) <= r) return true
            if (i > 0 && segDist(x, y, pts[i * 3 - 3], pts[i * 3 - 2], pts[i * 3], pts[i * 3 + 1]) <= r) return true
        }
        return false
    }

    companion object {
        /** Same default curve as the Mac side (measured on the Tab Pen Plus; see NOTES.md). */
        fun pressureCurve(p: Float): Float = ((p - 0.02f) / 0.88f).coerceIn(0f, 1f).pow(1.66f)

        fun segDist(px: Float, py: Float, ax: Float, ay: Float, bx: Float, by: Float): Float {
            val dx = bx - ax; val dy = by - ay
            val l2 = dx * dx + dy * dy
            val t = if (l2 == 0f) 0f else (((px - ax) * dx + (py - ay) * dy) / l2).coerceIn(0f, 1f)
            return hypot(px - (ax + t * dx), py - (ay + t * dy))
        }
    }
}

class ImageItem(val file: String, var x: Float, var y: Float, var w: Float, var h: Float, val bitmap: Bitmap) {
    fun contains(px: Float, py: Float) = px >= x && px <= x + w && py >= y && py <= y + h
}

sealed class Edit {
    class AddStroke(val s: Stroke) : Edit()
    class RemoveStrokes(val removed: List<Pair<Int, Stroke>>) : Edit()   // (index, stroke), ascending
    class AddImage(val img: ImageItem) : Edit()
    class RemoveImage(val index: Int, val img: ImageItem) : Edit()
    class MoveImage(val img: ImageItem, val from: FloatArray, val to: FloatArray) : Edit()  // x, y, w, h
    class Clear(val strokes: List<Stroke>, val images: List<ImageItem>) : Edit()
}

/**
 * The scratchpad document: one unbounded canvas of strokes and images, with undo/redo.
 *
 * On disk (app-private storage, `files/scratchpad/`):
 *   doc.bin  — big-endian: "TPSC", int version(1), float viewScale, viewTx, viewTy,
 *              int strokeCount, per stroke { int color, float width, byte highlighter, int n, n × (float x, y, pressure) },
 *              int imageCount, per image { UTF file name, float x, y, w, h }
 *   img-*.png / img-*.jpg — the pasted images, referenced by name from doc.bin.
 */
class ScratchDoc(private val dir: File) {
    val strokes = ArrayList<Stroke>()
    val images = ArrayList<ImageItem>()
    var viewScale = 1f; var viewTx = 0f; var viewTy = 0f
    var hasSavedView = false
    private val undo = ArrayList<Edit>()
    private val redo = ArrayList<Edit>()
    var onChanged: (() -> Unit)? = null

    val canUndo get() = undo.isNotEmpty()
    val canRedo get() = redo.isNotEmpty()

    fun apply(e: Edit) {
        perform(e); undo += e; redo.clear()
        if (undo.size > 300) undo.removeAt(0)
        onChanged?.invoke()
    }

    /** Records an edit whose effect has already been applied (e.g. an image drag). */
    fun record(e: Edit) { undo += e; redo.clear(); onChanged?.invoke() }

    fun undo() { val e = undo.removeLastOrNull() ?: return; revert(e); redo += e; onChanged?.invoke() }
    fun redo() { val e = redo.removeLastOrNull() ?: return; perform(e); undo += e; onChanged?.invoke() }

    private fun perform(e: Edit) {
        when (e) {
            is Edit.AddStroke -> strokes += e.s
            is Edit.RemoveStrokes -> for ((_, s) in e.removed) strokes.remove(s)
            is Edit.AddImage -> images += e.img
            is Edit.RemoveImage -> images.remove(e.img)
            is Edit.MoveImage -> e.img.set(e.to)
            is Edit.Clear -> { strokes.clear(); images.clear() }
        }
    }

    private fun revert(e: Edit) {
        when (e) {
            is Edit.AddStroke -> strokes.remove(e.s)
            is Edit.RemoveStrokes -> for ((i, s) in e.removed) strokes.add(min(i, strokes.size), s)
            is Edit.AddImage -> images.remove(e.img)
            is Edit.RemoveImage -> images.add(min(e.index, images.size), e.img)
            is Edit.MoveImage -> e.img.set(e.from)
            is Edit.Clear -> { strokes += e.strokes; images += e.images }
        }
    }

    private fun ImageItem.set(v: FloatArray) { x = v[0]; y = v[1]; w = v[2]; h = v[3] }

    fun serialize(): ByteArray {
        val bytes = ByteArrayOutputStream(64 + strokes.sumOf { it.n } * 12)
        DataOutputStream(bytes).use { o ->
            o.writeBytes("TPSC"); o.writeInt(1)
            o.writeFloat(viewScale); o.writeFloat(viewTx); o.writeFloat(viewTy)
            o.writeInt(strokes.size)
            for (s in strokes) {
                o.writeInt(s.color); o.writeFloat(s.width); o.writeByte(if (s.highlighter) 1 else 0); o.writeInt(s.n)
                for (i in 0 until s.n * 3) o.writeFloat(s.pts[i])
            }
            o.writeInt(images.size)
            for (im in images) { o.writeUTF(im.file); o.writeFloat(im.x); o.writeFloat(im.y); o.writeFloat(im.w); o.writeFloat(im.h) }
        }
        return bytes.toByteArray()
    }

    /** Atomic: write to a temp file, then rename over the old one. */
    fun write(data: ByteArray) {
        dir.mkdirs()
        val tmp = File(dir, "doc.bin.tmp")
        tmp.writeBytes(data)
        tmp.renameTo(File(dir, "doc.bin"))
        // Remove image files nothing refers to any more (deleted and no longer undoable).
        val keep = HashSet<String>()
        images.forEach { keep += it.file }
        (undo + redo).forEach {
            when (it) {
                is Edit.AddImage -> keep += it.img.file
                is Edit.RemoveImage -> keep += it.img.file
                is Edit.Clear -> it.images.forEach { im -> keep += im.file }
                else -> {}
            }
        }
        dir.listFiles()?.filter { it.name.startsWith("img-") && it.name !in keep }?.forEach { it.delete() }
    }

    fun load() {
        val f = File(dir, "doc.bin")
        if (!f.exists()) return
        try {
            DataInputStream(f.inputStream().buffered()).use { i ->
                val magic = ByteArray(4); i.readFully(magic)
                if (String(magic) != "TPSC" || i.readInt() != 1) return
                viewScale = i.readFloat(); viewTx = i.readFloat(); viewTy = i.readFloat(); hasSavedView = true
                repeat(i.readInt()) {
                    val s = Stroke(i.readInt(), i.readFloat(), i.readByte().toInt() == 1)
                    repeat(i.readInt()) { s.add(i.readFloat(), i.readFloat(), i.readFloat()) }
                    strokes += s
                }
                repeat(i.readInt()) {
                    val name = i.readUTF()
                    val x = i.readFloat(); val y = i.readFloat(); val w = i.readFloat(); val h = i.readFloat()
                    val bmp = BitmapFactory.decodeFile(File(dir, name).path)
                    if (bmp != null) images += ImageItem(name, x, y, w, h, bmp)
                }
            }
        } catch (e: Exception) {
            android.util.Log.e("TPScratch", "load failed", e)
        }
    }

    /** Stores a bitmap as a new image file and returns its name. */
    fun storeImage(bmp: Bitmap): String {
        dir.mkdirs()
        val alpha = bmp.hasAlpha()
        val name = "img-${System.currentTimeMillis()}-${(Math.random() * 100000).toInt()}.${if (alpha) "png" else "jpg"}"
        File(dir, name).outputStream().use {
            bmp.compress(if (alpha) Bitmap.CompressFormat.PNG else Bitmap.CompressFormat.JPEG, 92, it)
        }
        return name
    }
}
