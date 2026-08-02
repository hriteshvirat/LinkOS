package com.linkos.ui.components

import android.content.ClipDescription
import android.net.Uri
import android.view.DragEvent
import android.view.View
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.linkos.ui.theme.LinkOSBlue

@Composable
fun FileDragDropTarget(
    modifier: Modifier = Modifier,
    onFilesDropped: (List<Uri>) -> Unit,
    content: @Composable BoxScope.() -> Unit
) {
    val isDragActive = remember { mutableStateOf(false) }

    Box(modifier = modifier) {
        content()

        AndroidView(
            modifier = Modifier.fillMaxSize(),
            factory = { context ->
                View(context).apply {
                    setOnDragListener { _, event ->
                        when (event.action) {
                            DragEvent.ACTION_DRAG_STARTED -> {
                                true
                            }
                            DragEvent.ACTION_DRAG_ENTERED -> {
                                isDragActive.value = true
                                true
                            }
                            DragEvent.ACTION_DRAG_EXITED, DragEvent.ACTION_DRAG_ENDED -> {
                                isDragActive.value = false
                                true
                            }
                            DragEvent.ACTION_DROP -> {
                                val clipData = event.clipData
                                if (clipData != null) {
                                    val uris = mutableListOf<Uri>()
                                    for (i in 0 until clipData.itemCount) {
                                        val item = clipData.getItemAt(i)
                                        val uri = item.uri
                                        if (uri != null) {
                                            uris.add(uri)
                                        }
                                    }
                                    if (uris.isNotEmpty()) {
                                        onFilesDropped(uris)
                                    }
                                }
                                isDragActive.value = false
                                true
                            }
                            else -> false
                        }
                    }
                }
            },
            update = {}
        )

        if (isDragActive.value) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(Color(0x660088FF))
                    .border(3.dp, LinkOSBlue, RoundedCornerShape(12.dp)),
                contentAlignment = Alignment.Center
            ) {
                Text(
                    text = "Drop Files to Sync to Mac",
                    color = Color.White,
                    fontSize = 16.sp,
                    fontWeight = androidx.compose.ui.text.font.FontWeight.Bold
                )
            }
        }
    }
}
