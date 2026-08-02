package com.linkos.features.clipboard

import androidx.lifecycle.ViewModel
import com.linkos.core.network.WebSocketClient
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.StateFlow
import java.util.UUID
import javax.inject.Inject

enum class ClipboardType {
    TEXT,
    RICH_TEXT,
    IMAGE,
    FILE_REFERENCE,
    URL,
    CODE_SNIPPET
}

data class ClipboardHistoryItem(
    val id: String,
    val contentType: ClipboardType,
    val previewText: String,
    val fullText: String?,
    val mimeType: String,
    val sourceApp: String?,
    val timestamp: Long,
    var isPinned: Boolean = false,
    var isFavourite: Boolean = false,
    val sizeBytes: Int
)

@HiltViewModel
class ClipboardViewModel @Inject constructor(
    private val clipboardHistoryManager: ClipboardHistoryManager,
    private val webSocketClient: WebSocketClient
) : ViewModel() {

    val history: StateFlow<List<ClipboardHistoryItem>> = clipboardHistoryManager.history

    fun togglePin(id: String) {
        clipboardHistoryManager.togglePin(id)
    }

    fun toggleFavourite(id: String) {
        clipboardHistoryManager.toggleFavourite(id)
    }

    fun deleteItem(id: String) {
        clipboardHistoryManager.deleteItem(id)
    }

    fun clearAllUnpinned() {
        clipboardHistoryManager.clearHistory()
    }

    fun sendToMac(text: String) {
        webSocketClient.sendEnvelope("clipboard", text, type = "event")
    }

    fun addClipboardItem(text: String) {
        val now = System.currentTimeMillis()
        val historyItem = ClipboardHistoryItem(
            id = UUID.randomUUID().toString(),
            contentType = if (text.startsWith("http")) ClipboardType.URL else ClipboardType.TEXT,
            previewText = text.take(100),
            fullText = text,
            mimeType = "text/plain",
            sourceApp = "Android Device",
            timestamp = now,
            sizeBytes = text.length
        )
        clipboardHistoryManager.addItem(historyItem)
    }
}
