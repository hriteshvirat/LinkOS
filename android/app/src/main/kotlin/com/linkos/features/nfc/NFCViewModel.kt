package com.linkos.features.nfc

import androidx.lifecycle.ViewModel
import com.linkos.core.network.WebSocketClient
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import javax.inject.Inject

enum class NFCActionType(val label: String) {
    UNLOCK_MAC("Unlock Mac"),
    LOCK_MAC("Lock Mac"),
    OPEN_WORKSPACE("Open Developer Workspace"),
    LAUNCH_APPS("Launch Core Apps"),
    RUN_WORKFLOW("Run AI Workflow"),
    START_REMOTE_SESSION("Start Remote Desktop")
}

@HiltViewModel
class NFCViewModel @Inject constructor(
    private val webSocketClient: WebSocketClient
) : ViewModel() {

    private val _selectedAction = MutableStateFlow(NFCActionType.UNLOCK_MAC)
    val selectedAction: StateFlow<NFCActionType> = _selectedAction.asStateFlow()

    fun selectAction(action: NFCActionType) {
        _selectedAction.value = action
    }

    fun executeNFCAction(action: NFCActionType) {
        val payload = buildJsonObject {
            put("action", "nfc_tap")
            put("nfc_action", action.name)
        }.toString()
        webSocketClient.send(payload.toByteArray(Charsets.UTF_8))
    }
}
