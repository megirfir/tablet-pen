package dev.tabletpen.app.mirror

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView

private val COLORS = listOf(Color(0xFF1E5BD8), Color(0xFFD0342C), Color(0xFF1E8E3E), Color(0xFFF29900), Color(0xFF8E24AA), Color(0xFF141418), Color(0xFFFFFFFF))
private val WIDTHS = listOf("Fine" to 2.5f, "Medium" to 4f, "Bold" to 8f)

/**
 * Mirror tab: the Mac's screen with a doodle layer on top.
 *
 * @param makeView      builds the MirrorView (the activity owns the decoder and the link)
 * @param status        text shown over the picture area while there is no picture yet ("" = live)
 * @param setPenButton  registers the pen side-button handler; it returns true when the click was used here
 * @param onLeave       the tab is being left
 */
@Composable
fun MirrorScreen(
    ink: MirrorInk, makeView: (android.content.Context) -> MirrorView, status: String,
    setPenButton: (((Int) -> Boolean)?) -> Unit, onLeave: () -> Unit,
) {
    var view by remember { mutableStateOf<MirrorView?>(null) }
    var tool by remember { mutableStateOf(MirrorTool.Draw) }
    var color by remember { mutableStateOf(COLORS[0]) }
    var width by remember { mutableStateOf(4f) }
    var version by remember { mutableIntStateOf(0) }       // bumps on every doodle change, to refresh undo/redo state

    fun pick(t: MirrorTool) { tool = t; view?.overlay?.tool = t }

    DisposableEffect(Unit) {
        // Pen side button. While the pen controls the Mac it stays a right-click; while doodling:
        // click = switch between drawing and erasing, double click = undo, long press = redo.
        setPenButton { kind ->
            if (tool == MirrorTool.Control) false
            else {
                when (kind) {
                    1 -> pick(if (tool == MirrorTool.Erase) MirrorTool.Draw else MirrorTool.Erase)
                    2 -> { ink.undo(); version++ }
                    3 -> { ink.redo(); version++ }
                }
                true
            }
        }
        onDispose { setPenButton(null); onLeave() }
    }

    Column(Modifier.fillMaxSize()) {
        Row(
            Modifier.fillMaxWidth().background(Color(0xFF24242C)).horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("Pen:", color = Color(0xFFB0B0B8))
            Spacer(Modifier.width(8.dp))
            FilterChip(selected = tool == MirrorTool.Draw, onClick = { pick(MirrorTool.Draw) }, label = { Text("Doodle") })
            Spacer(Modifier.width(6.dp))
            FilterChip(selected = tool == MirrorTool.Erase, onClick = { pick(MirrorTool.Erase) }, label = { Text("Erase") })
            Spacer(Modifier.width(6.dp))
            FilterChip(selected = tool == MirrorTool.Control, onClick = { pick(MirrorTool.Control) }, label = { Text("Control Mac") })
            Spacer(Modifier.width(16.dp))
            for (c in COLORS) {
                Box(
                    Modifier.padding(horizontal = 4.dp).size(30.dp).clip(CircleShape).background(c)
                        .border(if (c == color) 3.dp else 1.dp, if (c == color) Color(0xFF8AB4F8) else Color(0xFF666666), CircleShape)
                        .clickable { color = c; view?.overlay?.color = c.toArgb(); if (tool != MirrorTool.Draw) pick(MirrorTool.Draw) }
                )
            }
            Spacer(Modifier.width(10.dp))
            for ((name, w) in WIDTHS) {
                FilterChip(selected = width == w, onClick = { width = w; view?.overlay?.strokeWidth = w }, label = { Text(name) })
                Spacer(Modifier.width(6.dp))
            }
            Spacer(Modifier.width(10.dp))
            // `version` is read so these re-evaluate after each edit.
            TextButton(onClick = { ink.undo(); version++ }, enabled = version >= 0 && ink.canUndo) { Text("Undo") }
            TextButton(onClick = { ink.redo(); version++ }, enabled = version >= 0 && ink.canRedo) { Text("Redo") }
            TextButton(onClick = { ink.clear(); version++ }, enabled = version >= 0 && ink.strokes.isNotEmpty()) { Text("Clear doodles") }
            Spacer(Modifier.width(10.dp))
            Text("Fingers: tap = click · 2 fingers = scroll / zoom · double-tap + drag = drag", color = Color(0xFF80808A))
        }
        Box(Modifier.fillMaxSize()) {
            AndroidView(
                factory = { ctx ->
                    makeView(ctx).also { v ->
                        v.overlay.tool = tool; v.overlay.color = color.toArgb(); v.overlay.strokeWidth = width
                        v.overlay.onInkChanged = { version++ }
                        view = v
                    }
                },
                update = { it.overlay.hint = status },
                modifier = Modifier.fillMaxSize(),
            )
        }
    }
}
