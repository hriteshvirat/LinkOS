package com.linkos.features.files

import android.content.Context
import android.content.SharedPreferences
import dagger.hilt.android.qualifiers.ApplicationContext
import org.json.JSONArray
import org.json.JSONObject
import javax.inject.Inject
import javax.inject.Singleton

data class TransferItem(
    val id: String,
    val fileName: String,
    val totalSize: Long,
    var bytesTransferred: Long,
    var status: String // "pending", "transferring", "paused", "completed", "failed"
)

@Singleton
class FileTransferQueueManager @Inject constructor(
    @ApplicationContext context: Context
) {
    private val prefs: SharedPreferences = context.getSharedPreferences("linkos_transfers", Context.MODE_PRIVATE)
    private val transfersMap = mutableMapOf<String, TransferItem>()

    init {
        loadTransfers()
    }

    fun addTransfer(id: String, fileName: String, totalSize: Long) {
        val item = TransferItem(id, fileName, totalSize, 0L, "pending")
        transfersMap[id] = item
        saveTransfers()
    }

    fun updateProgress(id: String, bytesTransferred: Long, status: String) {
        transfersMap[id]?.let {
            it.bytesTransferred = bytesTransferred
            it.status = status
            saveTransfers()
        }
    }

    fun getTransfer(id: String): TransferItem? {
        return transfersMap[id]
    }

    private fun saveTransfers() {
        val arr = JSONArray()
        for (item in transfersMap.values) {
            val obj = JSONObject().apply {
                put("id", item.id)
                put("fileName", item.fileName)
                put("totalSize", item.totalSize)
                put("bytesTransferred", item.bytesTransferred)
                put("status", item.status)
            }
            arr.put(obj)
        }
        prefs.edit().putString("queue_list", arr.toString()).apply()
    }

    private fun loadTransfers() {
        val str = prefs.getString("queue_list", null) ?: return
        try {
            val arr = JSONArray(str)
            for (i in 0 until arr.length()) {
                val obj = arr.getJSONObject(i)
                val item = TransferItem(
                    id = obj.getString("id"),
                    fileName = obj.getString("fileName"),
                    totalSize = obj.getLong("totalSize"),
                    bytesTransferred = obj.getLong("bytesTransferred"),
                    status = obj.getString("status")
                )
                transfersMap[item.id] = item
            }
        } catch (e: Exception) {
            // Ignore
        }
    }
}
