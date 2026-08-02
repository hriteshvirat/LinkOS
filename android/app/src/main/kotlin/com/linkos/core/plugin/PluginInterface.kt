package com.linkos.core.plugin

/**
 * Plugin interface — every LinkOS feature implements this.
 * Plugins are modular, independently activatable, and communicate
 * through stable interfaces rather than direct dependencies.
 */
interface LinkOSPlugin {
    /** Unique plugin identifier */
    val pluginId: String

    /** Human-readable display name */
    val displayName: String

    /** Plugin version (semver) */
    val version: String

    /** Channels this plugin subscribes to */
    val subscribedChannels: Set<String>

    /** Permissions required by this plugin */
    val requiredPermissions: Set<String>
        get() = emptySet()

    /** Whether the plugin is currently active */
    val isActive: Boolean

    /** Activate the plugin — set up resources */
    suspend fun activate()

    /** Deactivate the plugin — clean up resources */
    suspend fun deactivate()

    /** Handle an incoming message on a subscribed channel */
    suspend fun handleMessage(message: LinkOSMessage)

    /** Provide actions for the universal command palette */
    fun commandPaletteActions(): List<CommandPaletteAction> = emptyList()
}

/**
 * Internal message envelope used for routing between plugins.
 */
data class LinkOSMessage(
    val messageId: String,
    val type: MessageType,
    val channel: String,
    val timestamp: Long,
    val payload: ByteArray,
    val deviceId: String,
    val correlationId: String? = null,
) {
    enum class MessageType {
        REQUEST, RESPONSE, EVENT, STREAM, ACK, ERROR
    }

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is LinkOSMessage) return false
        return messageId == other.messageId
    }

    override fun hashCode(): Int = messageId.hashCode()
}

/**
 * Action exposed to the universal command palette.
 */
data class CommandPaletteAction(
    val id: String,
    val title: String,
    val subtitle: String? = null,
    val icon: String,
    val keywords: List<String> = emptyList(),
    val category: String,
    val action: suspend () -> Unit,
)

/**
 * Manages plugin lifecycle: registration, activation, deactivation, message routing.
 */
class PluginManager {
    private val registeredPlugins = mutableMapOf<String, LinkOSPlugin>()
    private val activePlugins = mutableMapOf<String, LinkOSPlugin>()

    fun register(plugin: LinkOSPlugin) {
        registeredPlugins[plugin.pluginId] = plugin
    }

    suspend fun activate(pluginId: String) {
        val plugin = registeredPlugins[pluginId] ?: return
        if (plugin.isActive) return
        plugin.activate()
        activePlugins[pluginId] = plugin
    }

    suspend fun deactivate(pluginId: String) {
        val plugin = activePlugins.remove(pluginId) ?: return
        plugin.deactivate()
    }

    suspend fun deactivateAll() {
        activePlugins.keys.toList().forEach { deactivate(it) }
    }

    suspend fun routeMessage(message: LinkOSMessage) {
        activePlugins.values
            .filter { message.channel in it.subscribedChannels }
            .forEach { it.handleMessage(message) }
    }

    fun allCommandPaletteActions(): List<CommandPaletteAction> =
        activePlugins.values.flatMap { it.commandPaletteActions() }
}
