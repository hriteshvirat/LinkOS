package com.linkos.features.clipboard

import android.content.Context
import android.content.SharedPreferences
import com.linkos.core.logging.LinkOSLogger
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class ClipboardHistoryManager @Inject constructor(
    @ApplicationContext private val context: Context
) {
    private val prefs: SharedPreferences = context.getSharedPreferences("linkos_clipboard_history", Context.MODE_PRIVATE)
    private val _history = MutableStateFlow<List<ClipboardHistoryItem>>(emptyList())
    val history: StateFlow<List<ClipboardHistoryItem>> = _history.asStateFlow()

    init {
        loadHistory()
    }

    private fun loadHistory() {
        try {
            val jsonStr = prefs.getString("history", "[]") ?: "[]"
            val array = JSONArray(jsonStr)
            val items = mutableListOf<ClipboardHistoryItem>()
            for (i in 0 until array.length()) {
                val obj = array.getJSONObject(i)
                val typeStr = obj.optString("contentType", "TEXT").uppercase()
                val contentType = try { ClipboardType.valueOf(typeStr) } catch(e: Exception) { ClipboardType.TEXT }
                items.add(
                    ClipboardHistoryItem(
                        id = obj.optString("id", UUID.randomUUID().toString()),
                        contentType = contentType,
                        previewText = obj.optString("previewText", ""),
                        fullText = obj.optString("fullText", ""),
                        mimeType = obj.optString("mimeType", "text/plain"),
                        sourceApp = obj.optString("sourceApp", "Unknown"),
                        timestamp = obj.optLong("timestamp", System.currentTimeMillis()),
                        isPinned = obj.optBoolean("isPinned", false),
                        isFavourite = obj.optBoolean("isFavourite", false),
                        sizeBytes = obj.optInt("sizeBytes", 0)
                    )
                )
            }
            _history.value = items.sortedByDescending { it.timestamp }
        } catch (e: Exception) {
            LinkOSLogger.error("Failed to load clipboard history: ${e.message}", "Clipboard")
        }
    }

    fun saveHistory() {
        try {
            val array = JSONArray()
            _history.value.forEach { item ->
                val obj = JSONObject().apply {
                    put("id", item.id)
                    put("contentType", item.contentType.name)
                    put("previewText", item.previewText)
                    put("fullText", item.fullText)
                    put("mimeType", item.mimeType)
                    put("sourceApp", item.sourceApp)
                    put("timestamp", item.timestamp)
                    put("isPinned", item.isPinned)
                    put("isFavourite", item.isFavourite)
                    put("sizeBytes", item.sizeBytes)
                }
                array.put(obj)
            }
            prefs.edit().putString("history", array.toString()).apply()
        } catch (e: Exception) {
            LinkOSLogger.error("Failed to save clipboard history: ${e.message}", "Clipboard")
        }
    }

    fun addItem(item: ClipboardHistoryItem) {
        val currentList = _history.value.toMutableList()
        // Deduplicate: remove any item with identical text content
        currentList.removeAll { it.fullText == item.fullText }
        currentList.add(0, item)
        // Cap the list at 100 items to prevent bloat
        if (currentList.size > 100) {
            val pinned = currentList.filter { it.isPinned }
            val unpinned = currentList.filter { !it.isPinned }.take(100 - pinned.size)
            _history.value = (pinned + unpinned).sortedByDescending { it.timestamp }
        } else {
            _history.value = currentList
        }
        saveHistory()
    }

    fun deleteItem(id: String) {
        _history.value = _history.value.filter { it.id != id }
        saveHistory()
    }

    fun togglePin(id: String) {
        _history.value = _history.value.map {
            if (it.id == id) it.copy(isPinned = !it.isPinned) else it
        }
        saveHistory()
    }

    fun toggleFavourite(id: String) {
        _history.value = _history.value.map {
            if (it.id == id) it.copy(isFavourite = !it.isFavourite) else it
        }
        saveHistory()
    }

    fun clearHistory() {
        _history.value = _history.value.filter { it.isPinned || it.isFavourite }
        saveHistory()
    }
}
