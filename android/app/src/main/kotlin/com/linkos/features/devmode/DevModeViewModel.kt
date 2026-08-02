package com.linkos.features.devmode

import androidx.lifecycle.ViewModel
import com.linkos.core.network.WebSocketClient
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import javax.inject.Inject

data class GitStatusItem(
    val repoName: String = "LinkOS",
    val branch: String = "main",
    val clean: Boolean = true,
    val ahead: Int = 0,
    val behind: Int = 0
)

data class DockerItem(
    val id: String,
    val name: String,
    val image: String,
    val status: String,
    val isRunning: Boolean
)

@HiltViewModel
class DevModeViewModel @Inject constructor(
    private val webSocketClient: WebSocketClient
) : ViewModel() {

    private val _gitStatus = MutableStateFlow(GitStatusItem())
    val gitStatus: StateFlow<GitStatusItem> = _gitStatus.asStateFlow()

    private val _containers = MutableStateFlow(
        listOf(
            DockerItem("c1", "redis-cache", "redis:latest", "Up 2 hours", true),
            DockerItem("c2", "postgres-db", "postgres:16", "Up 2 hours", true)
        )
    )
    val containers: StateFlow<List<DockerItem>> = _containers.asStateFlow()
}
