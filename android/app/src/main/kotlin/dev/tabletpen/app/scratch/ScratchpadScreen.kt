package dev.tabletpen.app.scratch

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
import androidx.compose.material3.AlertDialog
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import dev.tabletpen.app.MainActivity

private val COLORS = listOf(Color(0xFF141418), Color(0xFF1E5BD8), Color(0xFFD0342C), Color(0xFF1E8E3E), Color(0xFFF29900), Color(0xFF8E24AA))
private val WIDTHS = listOf("Fine" to 2.5f, "Medium" to 4f, "Bold" to 8f)

@Composable
fun ScratchpadScreen(doc: ScratchDoc, onView: (ScratchpadView) -> Unit, onPaste: () -> Unit, onPick: () -> Unit) {
    var view by remember { mutableStateOf<ScratchpadView?>(null) }
    var tool by remember { mutableStateOf(ScratchTool.Pen) }
    var lastInk by remember { mutableStateOf(ScratchTool.Pen) }
    var color by remember { mutableStateOf(COLORS[0]) }
    var width by remember { mutableStateOf(4f) }
    var hasSelection by remember { mutableStateOf(false) }
    var version by remember { mutableIntStateOf(0) }       // bumps on every document change, to refresh undo/redo state
    var confirmClear by remember { mutableStateOf(false) }

    fun pick(t: ScratchTool) {
        tool = t; view?.tool = t
        if (t == ScratchTool.Pen || t == ScratchTool.Highlighter) lastInk = t
    }

    val activity = LocalContext.current as? MainActivity
    DisposableEffect(Unit) {
        // Pen side button: click = switch between ink and eraser, double click = undo, long press = redo.
        activity?.scratchPenButton = { kind ->
            when (kind) {
                1 -> pick(if (tool == ScratchTool.Eraser) lastInk else ScratchTool.Eraser)
                2 -> view?.undo()
                3 -> view?.redo()
            }
        }
        onDispose { activity?.scratchPenButton = null }
    }

    Column(Modifier.fillMaxSize()) {
        Row(
            Modifier.fillMaxWidth().background(Color(0xFF24242C)).horizontalScroll(rememberScrollState())
                .padding(horizontal = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            for (t in ScratchTool.entries) {
                FilterChip(selected = tool == t, onClick = { pick(t) }, label = { Text(if (t == ScratchTool.Select) "Move image" else t.name) })
                Spacer(Modifier.width(6.dp))
            }
            Spacer(Modifier.width(10.dp))
            for (c in COLORS) {
                Box(
                    Modifier.padding(horizontal = 4.dp).size(30.dp).clip(CircleShape).background(c)
                        .border(if (c == color) 3.dp else 1.dp, if (c == color) Color.White else Color(0xFF666666), CircleShape)
                        .clickable { color = c; view?.color = c.toArgb() }
                )
            }
            Spacer(Modifier.width(10.dp))
            for ((name, w) in WIDTHS) {
                FilterChip(selected = width == w, onClick = { width = w; view?.strokeWidth = w }, label = { Text(name) })
                Spacer(Modifier.width(6.dp))
            }
            Spacer(Modifier.width(10.dp))
            // `version` is read so these re-evaluate after each edit.
            TextButton(onClick = { view?.undo() }, enabled = version >= 0 && doc.canUndo) { Text("Undo") }
            TextButton(onClick = { view?.redo() }, enabled = version >= 0 && doc.canRedo) { Text("Redo") }
            TextButton(onClick = onPaste) { Text("Paste image") }
            TextButton(onClick = onPick) { Text("Add image") }
            if (hasSelection) TextButton(onClick = { view?.deleteSelected() }) { Text("Delete image", color = Color(0xFFFF8A80)) }
            TextButton(onClick = { view?.resetView() }) { Text("Reset view") }
            TextButton(onClick = { confirmClear = true }) { Text("Clear") }
        }
        AndroidView(
            factory = { ctx ->
                ScratchpadView(ctx, doc).also { v ->
                    v.onSelection = { hasSelection = it; if (it) tool = ScratchTool.Select }
                    val saved = doc.onChanged
                    doc.onChanged = { saved?.invoke(); version++ }
                    v.color = color.toArgb(); v.strokeWidth = width; v.tool = tool
                    view = v; onView(v)
                }
            },
            modifier = Modifier.fillMaxSize(),
        )
    }

    if (confirmClear) {
        AlertDialog(
            onDismissRequest = { confirmClear = false },
            title = { Text("Clear the scratchpad?") },
            text = { Text("Removes all ink and images. You can still undo it until you leave the app.") },
            confirmButton = { TextButton(onClick = { confirmClear = false; view?.clearAll() }) { Text("Clear") } },
            dismissButton = { TextButton(onClick = { confirmClear = false }) { Text("Cancel") } },
        )
    }
}
